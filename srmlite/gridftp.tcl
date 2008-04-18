
package require gss::context
package require dict
package require log

package require XOTcl

namespace eval ::srmlite::gridftp {
    namespace import ::xotcl::*

# -------------------------------------------------------------------------

    set bufCommandsRetr {
        {SITE RETRBUFSIZE}
        {SITE RBUFSZ}
        {SITE RBUFSIZ}
        {SITE BUFSIZE}
    }

# -------------------------------------------------------------------------

    set bufCommandsStor {
        {SITE STORBUFIZE}
        {SITE SBUFSZ}
        {SITE SBUFSIZ}
        {SITE BUFSIZE}
    }

# -------------------------------------------------------------------------

    array set respStor {
        connect   {220 auth}
        auth      {334 handshake}
        handshake {335 handshake 235 user}
        user      {200 pass 331 pass}
        pass      {200 type 230 type}
        type      {200 mode}
        mode      {200 dcau}
        dcau      {200 bufStor 500 bufStor}
        bufStor   {200 pasv 500 bufStor}
        pasv      {227 stor}
        stor      {226 done}
    }

# -------------------------------------------------------------------------

    array set respRetr {
        connect   {220 auth}
        auth      {334 handshake}
        handshake {335 handshake 235 user}
        user      {200 pass 331 pass}
        pass      {200 type 230 type}
        type      {200 mode}
        mode      {200 dcau}
        dcau      {200 bufRetr 500 bufRetr}
        bufRetr   {200 opts 500 bufRetr}
        opts      {200 port 500 port}
        port      {200 retr}
        retr      {226 wait}
    }

# -------------------------------------------------------------------------

    proc ExtractHostFile {url} {

        set exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:([0-9]+))?(/srm/managerv1\?SFN=)?(/.*)?$}
        if {![regexp -nocase $exp $url x prefix proto user host y port z file]} {
            log::log error "Unsupported URL $url"
            return {}
        }

        set file [file normalize $file]

        return [list $host $file]
    }

# -------------------------------------------------------------------------

    Class GridFtpTransfer

# -------------------------------------------------------------------------

    GridFtpTransfer instproc start {fileId certProxy srcTURL dstTURL} {

        set hostfile [ExtractHostFile $srcTURL]

        set retr [GridFtpClient new -childof [self]]
	$retr set certProxy $certProxy
	$retr set fileId $fileId
        $retr set host [lindex $hostfile 0]
        $retr set file [lindex $hostfile 1]
	$retr set stor 0

        set hostfile [ExtractHostFile $dstTURL]

        set stor [GridFtpClient new -childof [self]]
	$stor set certProxy $certProxy
        $stor set fileId $fileId
        $stor set host [lindex $hostfile 0]
        $stor set file [lindex $hostfile 1]
	$stor set stor 1
	$stor forward retr $retr start
        $stor start
    }

# -------------------------------------------------------------------------

    GridFtpTransfer instproc stop {} {
        foreach client [my info children] {
            $client quit
        }
    }

# -------------------------------------------------------------------------

    Class GridFtpClient

# -------------------------------------------------------------------------

    GridFtpClient instproc log {level args} {
        my instvar fileId host
        log::log $level "\[fileId $fileId\] \[server $host\] [join $args { }]"
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc start {{port {}}} {
        my instvar certProxy host chan

        set chan [socket -async $host 2811]
        fconfigure $chan -blocking 0 -translation {auto crlf} -buffering line
        fileevent $chan readable [list [self] GetInput]

        my set context [gss::context $chan -gssimport $certProxy]
        my set buffer {}
        my set bufcmd 0
        my set state connect
        my set port $port

        my log debug "GridFtpClient import [my set context]"
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc GetInput {} {

        my instvar chan context state code buffer

        if {[catch {gets $chan line} readCount]} {
            my log error $readCount
            my close
            my failure "Error during gridftp transfer"
            return
        }

        if {$readCount == -1} {
            if {[eof $chan]} {
                my close
                my log error "Broken connection during gridftp transfer"
                my failure "Error during gridftp transfer"
            } else {
                my log warning "No full line available, retrying..."
            }
            return
        }

        if {![regexp -- {^-?(\d+)( |-)?(ADAT)?( |=)?(.*)$} $line -> rc ml adat eq msg]} {
            my log error "Unsupported response from FTP server\n$line"
        }

        set code $rc

        if {[string match {63?} $code]} {
            if {![string equal $context {}]} {
                if {[catch {$context unwrap $msg} result]} {
                    my close
                    my failure "Error during unwrap"
                    return
                } else {
                    set msg $result
                }
            }
        }

        append buffer $msg

        if {[string equal $ml {-}]} {
            my log debug "Multi-line mode, continue..."
            return
        }

        if {[string match {63?} $code]} {
            if {![regexp -- {^-?(\d+)( |-)?(.*)$} $buffer -> rc ml msg]} {
                my log error "Unsupported response from FTP server\n$line"
                return
            }

            set buffer $msg
            set code $rc
        }

        my ProcessInput

        set buffer {}
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc wrap {msg} {

        my instvar chan context

        if {[catch {$context wrap $msg} result]} {
            my close
            my failure "Error during wrap"
        } else {
            puts $chan $result
        }
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc ProcessInput {} {

        my instvar state code buffer stor

        my log debug "$state,$code"

        if {[string equal $state quit]} {
            my close
        }

        if {$stor} {
            upvar #0 ::srmlite::gridftp::respStor resp
        } else {
            upvar #0 ::srmlite::gridftp::respRetr resp
        }

        foreach {retCode newState} $resp($state) {
            if {[string equal $retCode $code]} {
    	        my $newState
    	        return
            }
        }

        if {[string match {1??} $code] || [string match {2??} $code]} {
            my log debug "[lindex [split $buffer "\n"] 0]"
        } else {
            my log error "Unknown state $state,$code"
            my log error "$buffer"
            my failure $buffer
        }
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc auth {} {
        my instvar chan
        puts $chan {AUTH GSSAPI}
        my set state auth
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc handshake {} {
        my instvar chan context state buffer

        if {[string equal $state auth]} {
            set buffer {}
        }

        if {[catch {$context handshake $buffer} result]} {
            my close
            my failure "Error during handshake"
        } else {
            puts $chan $result
        }

        set state handshake
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc user {} {
        my wrap {USER :globus-mapping:}
        my set state user
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc pass {} {
        my wrap {PASS dummy}
        my set state pass
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc type {} {
        my wrap {TYPE I}
        my set state type
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc mode {} {
        my wrap {MODE E}
        my set state mode
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc dcau {} {
        my wrap {DCAU N}
        my set state dcau
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc bufStor {} {
        variable bufCommandsStor
        my instvar state bufcmd

        if {$bufcmd >= [llength $bufCommandsStor]} {
            my log error "Failed to set STOR buffer size"
            my pasv
            return
        }
        set command [lindex $bufCommandsStor $bufcmd]
        my wrap "$command 1048576"
        incr bufcmd
        set state bufStor
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc bufRetr {} {
        variable bufCommandsRetr
        my instvar state bufcmd

        if {$bufcmd >= [llength $bufCommandsRetr]} {
            my log error "Failed to set RETR buffer size"
            opts $fileId $chan
            return
        }
        set command [lindex $bufCommandsRetr $bufcmd]
        my wrap "$command 1048576"
        incr bufcmd
        set state bufRetr
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc pasv {} {
        my wrap {PASV}
        my set state pasv
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc opts {} {
        my wrap {OPTS RETR Parallelism=8,8,8;}
        my set state opts
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc stor {} {
        my instvar fileId state buffer file
        regexp -- {\d+,\d+,\d+,\d+,\d+,\d+} $buffer port
        my wrap "STOR $file"
        set state stor
        my retr $port
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc port {} {
        my instvar state port
        my wrap "PORT $port"
        set state port
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc retr {} {
        my instvar state file
        my wrap "RETR $file"
        set state retr
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc done {} {
        my success
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc quit {} {
        my instvar chan state
        puts $chan {QUIT}
        set state quit
        my close
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc close {} {
        my instvar chan context afetrId

        fileevent $chan readable {}
        my log debug "close $chan"
        ::close $chan

        if {![string equal $context {}]} {
            my log debug "$context destroy"
            $context destroy
        }
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc wait {} {
        my instvar buffer
        my log debug "$buffer"
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc success {} {
        my instvar fileId
        SrmCopyDone $fileId
    }

# -------------------------------------------------------------------------

    GridFtpClient instproc failure {faultString} {
        my instvar fileId
        SrmFailed $fileId $faultString
    }

# -------------------------------------------------------------------------

   namespace export GridFtpTransfer
}

package provide srmlite::gridftp 0.3
