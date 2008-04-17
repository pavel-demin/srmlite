
package require gss::context
package require dict
package require log

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
    stor      {226 quit}
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

proc GridFtpGetInput {fileId chan} {

    upvar #0 GridFtp$chan data

    set prefix "\[fileId $fileId\] \[server $data(host)\]"

    if {[catch {gets $chan line} readCount]} {
        log::log error "$prefix $readCount"
        GridFtpClose $fileId $chan
        GridFtpStop $fileId
        eval $callbackFailure "Error during gridftp transfer"
        return
    }

    if {$readCount == -1} {
        if {[eof $chan]} {
            set state $data(state)
            GridFtpClose $fileId $chan
            if {$state != "quit"} {
                log::log error "$prefix Broken connection during gridftp transfer"
                GridFtpStop $fileId
                eval $callbackFailure "$prefix Error during gridftp transfer"
            }
        } else {
            log::log warning "$prefix No full line available, retrying..."
        }
        return
    }

    if {![regexp -- {^-?(\d+)( |-)?(ADAT)?( |=)?(.*)$} $line -> rc ml adat eq msg]} {
        log::log error "$prefix Unsupported response from FTP server\n$line"
    }

    set data(rc) $rc

    if {[string match {63?} $rc]} {
        set context $data(context)
        if {![string equal $context {}]} {
            if {[catch {$context unwrap $msg} result]} {
                GridFtpClose $fileId $chan
                GridFtpStop $fileId
                eval $callbackFailure "Error during unwrap"
                return
            } else {
                set msg $result
            }
        }
    }

    if {[string equal $ml {-}]} {
        append data(buffer) $msg
        log::log debug "$prefix Multi-line mode, continue..."
        return
    } else {
        append data(buffer) $msg
    }

    if {[string match {63?} $rc]} {
        set line $data(buffer)

        if {![regexp -- {^-?(\d+)( |-)?(.*)$} $line -> rc ml msg]} {
            log::log error "$prefix Unsupported response from FTP server\n$line"
            return
        }

        set data(buffer) $msg
        set data(rc) $rc
    }

    GridFtpProcessInput $fileId $chan

    set data(buffer) {}
}

# -------------------------------------------------------------------------

proc GridFtpHandshake {fileId chan msg} {

    upvar #0 GridFtp$chan data

    if {[catch {$data(context) handshake $msg} result]} {
        GridFtpClose $fileId $chan
        GridFtpStop $fileId
        eval $callbackFailure "Error during handshake"
    } else {
        puts $chan $result
    }
}

# -------------------------------------------------------------------------

proc GridFtpWrap {fileId chan msg} {

    upvar #0 GridFtp$chan data

    if {[catch {$data(context) wrap $msg} result]} {
        GridFtpClose $fileId $chan
        GridFtpStop $fileId
        eval $callbackFailure "Error during wrap"
    } else {
        puts $chan $result
    }
}

# -------------------------------------------------------------------------

proc GridFtpProcessInput {fileId chan} {

    upvar #0 GridFtp$chan data

    set prefix "\[fileId $fileId\] \[server $data(host)\]"

    log::log debug "$prefix $data(state),$data(rc)"

    if {[string equal $data(state) quit]} {
        GridFtpClose $fileId $chan
    }

    if {$data(stor)} {
        upvar #0 respStor resp
    } else {
        upvar #0 respRetr resp
    }

    foreach {code newState} $resp($data(state)) {
        if {$data(rc) == $code} {
	    $newState $fileId $chan
	    return
        }
    }

    if {[string match {1??}] || [string match {2??}]} {
    {
        log::log debug "$prefix [lindex [split $line "\n"] 0]"
    } else {
        log::log error "$prefix Unknown state $data(state),$data(rc)"
        log::log error "$prefix $data(buffer)"
        GridFtpStop $fileId
        eval $callbackFailure $data(buffer)
    }
}

# -------------------------------------------------------------------------

proc auth {fileId chan} {
    upvar #0 GridFtp$chan data
    puts $chan {AUTH GSSAPI}
    set data(state) auth
}

# -------------------------------------------------------------------------

proc handshake {fileId chan} {
    upvar #0 GridFtp$chan data
    puts $chan {AUTH GSSAPI}
    if {[string equal $data(state) auth]} {
        GridFtpHandshake $fileId $chan $data(buffer)
    } else {
        GridFtpHandshake $fileId $chan $data(buffer)
    }
    set data(state) handshake
}

# -------------------------------------------------------------------------

proc user {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan {USER :globus-mapping:}
    set data(state) user
}

# -------------------------------------------------------------------------

proc pass {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan {PASS dummy}
    set data(state) pass
}

# -------------------------------------------------------------------------

proc type {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan {TYPE I}
    set data(state) type
}

# -------------------------------------------------------------------------

proc mode {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan {MODE E}
    set data(state) mode
}

# -------------------------------------------------------------------------

proc dcau {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan {DCAU N}
    set data(state) dcau
}

# -------------------------------------------------------------------------

proc bufStor {fileId chan} {
    upvar #0 GridFtp$chan data
    set prefix "\[fileId $fileId\] \[server $data(host)\]"

    if {$data(bufcmd) >= [llength $bufCommandsStor]} {
        log::log error "$prefix Failed to set STOR buffer size"
        pasv $fileId $chan
        return
    }
    set command [lindex $bufCommandsStor $data(bufcmd)]
    GridFtpWrap $fileId $chan "$command 1048576"
    incr data(bufcmd)
    set data(state) bufRetr
}

# -------------------------------------------------------------------------

proc bufRetr {fileId chan} {
    upvar #0 GridFtp$chan data
    set prefix "\[fileId $fileId\] \[server $data(host)\]"

    if {$data(bufcmd) >= [llength $bufCommandsRetr]} {
        log::log error "$prefix Failed to set RETR buffer size"
        opts $fileId $chan
        return
    }
    set command [lindex $bufCommandsRetr $data(bufcmd)]
    GridFtpWrap $fileId $chan "$command 1048576"
    incr data(bufcmd)
    set data(state) bufRetr
}

# -------------------------------------------------------------------------

proc pasv {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan {PASV}
    set data(state) pasv
}

# -------------------------------------------------------------------------

proc opts {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan {OPTS RETR Parallelism=8,8,8;}
    set data(state) opts
}

# -------------------------------------------------------------------------

proc stor {fileId chan} {
    upvar #0 GridFtp$chan data
    regexp -- {\d+,\d+,\d+,\d+,\d+,\d+} $data(buffer) port
    GridFtpWrap $fileId $chan "STOR $data(file)"
    set data(state) stor
    GridFtpRetr $fileId $data(srcTURL) $port
}

# -------------------------------------------------------------------------

proc port {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan "PORT $data(port)"
    set data(state) port
}

# -------------------------------------------------------------------------

proc retr {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpWrap $fileId $chan "RETR $data(file)"
    set data(state) retr
}

# -------------------------------------------------------------------------

proc quit {fileId chan} {
    upvar #0 GridFtp$chan data
    GridFtpQuit $fileId $chan QUIT
    GridFtpStop $fileId
    eval $callbackSuccess
}

# -------------------------------------------------------------------------

proc wait {fileId chan} {
    upvar #0 GridFtp$chan data
    set prefix "\[fileId $fileId\] \[server $data(host)\]"
    log::log debug "$prefix $line"
}

# -------------------------------------------------------------------------

proc GridFtpRetr {fileId srcTURL port} {

    upvar #0 GridFtpIndex$fileId index
    upvar #0 SrmFile$fileId file
    set certProxy [dict get $file certProxy]

    set hostfile [ExtractHostFile $srcTURL]

    set chan [socket -async [lindex $hostfile 0] 2811]
    fconfigure $chan -blocking 0 -translation {auto crlf} -buffering line
    fileevent $chan readable [list GridFtpGetInput $fileId $chan]

    dict set index $chan 1

    upvar #0 GridFtp$chan data

    set data(context) [gss::context $chan -gssimport $certProxy]
    set data(afterId) {}
    set data(buffer) {}
    set data(bufcmd) 0
    set data(state) connect
    set data(stor) 0
    set data(port) $port
    set data(host) [lindex $hostfile 0]
    set data(file) [lindex $hostfile 1]

    set prefix "\[fileId $fileId\] \[server $data(host)\]"
    log::log debug "$prefix GridFtpRetr: import $data(context)"
}

# -------------------------------------------------------------------------

proc GridFtpCopy {fileId srcTURL dstTURL} {

    upvar #0 GridFtpIndex$fileId index
    upvar #0 SrmFile$fileId file
    set certProxy [dict get $file certProxy]

    set hostfile [ExtractHostFile $dstTURL]

    set chan [socket -async [lindex $hostfile 0] 2811]
    fconfigure $chan -blocking 0 -translation {auto crlf} -buffering line
    fileevent $chan readable [list GridFtpGetInput $fileId $chan]

    dict set index $chan 1

    upvar #0 GridFtp$chan data

    set data(context) [gss::context $chan -gssimport $certProxy]
    set data(afterId) {}
    set data(buffer) {}
    set data(bufcmd) 0
    set data(state) connect
    set data(stor) 1
    set data(port) {}
    set data(host) [lindex $hostfile 0]
    set data(file) [lindex $hostfile 1]
    set data(srcTURL) $srcTURL

    set prefix "\[fileId $fileId\] \[server $data(host)\]"
    log::log debug "$prefix GridFtpCopy: import $data(context)"
}

# -------------------------------------------------------------------------

proc GridFtpClose {fileId chan} {
    upvar #0 GridFtpIndex$fileId index
    upvar #0 GridFtp$chan data

    set channels [file channels $chan]
    set prefix "\[fileId $fileId\]"
    log::log debug "$prefix GridFtpClose $chan => $channels"

    if {![string equal $channels {}]} {
        fileevent $chan readable {}
        log::log debug "$prefix close $chan"
        ::close $chan
    }

    if {[info exists index]} {
        if {[dict exists $index $chan]} {
            dict unset index $chan
        }

        if {[dict size $index] == 0} {
            unset index
        }
    }

    if {[info exists data]} {
        set context $data(context)
        if {![string equal $context {}]} {
            log::log debug "$prefix $context destroy"
            $context destroy
        }

        set afterId $data(afterId)
        if {![string equal $afterId {}]} {
            after cancel $afterId
        }

        unset data
    }
}

# -------------------------------------------------------------------------

proc GridFtpQuit {fileId chan command} {
    upvar #0 GridFtpIndex$fileId index
    upvar #0 GridFtp$chan data

    if {[info exists data]} {
        if {[file channels $chan] != {} &&
            $data(state) != {quit}} {
            set data(state) quit
            puts $chan $command
        }
        if {[string equal $data(afterId) {}]} {
            set data(afterId) [after 30000 [list GridFtpClose $fileId $chan]]
        }
    }

    if {[info exists index]} {
        if {[dict exists $index $chan]} {
            dict unset index $chan
        }

        if {[dict size $index] == 0} {
            unset index
        }
    }
}

# -------------------------------------------------------------------------

proc GridFtpStop {fileId} {
    upvar #0 GridFtpIndex$fileId index

    if {![info exists index]} {
        log::log warning "GridFtpStop: Unknown file id $fileId"
        return
    }

    dict for {chan dummy} $index {
        GridFtpQuit $fileId $chan QUIT
        dict unset index $chan
    }

    unset index
}

# -------------------------------------------------------------------------

package provide srmlite::gridftp 0.2
