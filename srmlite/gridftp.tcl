
package require gss::context
package require log

# -------------------------------------------------------------------------

set rbufCommands {
    {SITE RETRBUFSIZE}
    {SITE RBUFSZ}
    {SITE RBUFSIZ}
    {SITE BUFSIZE}
}

# -------------------------------------------------------------------------

set sbufCommands {
    {SITE STORBUFIZE}
    {SITE SBUFSZ}
    {SITE SBUFSIZ}
    {SITE BUFSIZE}
}

# -------------------------------------------------------------------------

proc GridFtpGetInput {fileId chan} {

    upvar #0 GridFtp$chan data

    if {[catch {gets $chan line} readCount]} {
        log::log error $readCount
        GridFtpClose $chan
        GridFtpFailed $fileId $chan
        return
    }

    if {$readCount == -1} {
        if {[eof $chan]} {
            if {$data(state) != "quit"} {
                log::log error {Broken connection during gridftp transfer}
                GridFtpFailed $fileId $chan
            }
            GridFtpClose $chan
        } else {
            log::log warning {No full line available, retrying...}
        }
        return
    }

    if {![regexp -- {^-?(\d+)( |-)?(ADAT)?( |=)?(.*)$} $line -> rc ml adat eq msg]} {
		    log::log error "Unsupported response from FTP server\n$line"
	  }

	  set data(rc) $rc

	  if {[string match {63?} $rc]} {
        set msg [$data(context) unwrap $msg]
	  }

    if {[string equal $ml {-}]} {
        append data(buffer) $msg
        log::log debug {Multi-line mode, continue...}
        return
    } else {
        append data(buffer) $msg
    }

    GridFtpProcessClearInput $fileId $chan
}

# -------------------------------------------------------------------------

proc GridFtpProcessClearInput {fileId chan} {

    upvar #0 GridFtp$chan data

    log::log debug $data(state),$data(rc)

    switch -glob -- $data(state),$data(rc) {
        new,220 {
            puts $chan {AUTH GSSAPI}
            set data(state) auth
            set data(buffer) {}
        }
        auth,334 {
            puts $chan [$data(context) handshake {}]
            set data(state) handshake
            set data(buffer) {}
        }
        handshake,335 {
            puts $chan [$data(context) handshake $data(buffer)]
            set data(buffer) {}
        }
        handshake,235 {
            puts $chan [$data(context) wrap {USER :globus-mapping:}]
            set data(state) login
            set data(buffer) {}
        }
        quit,* {
            GridFtpClose $chan
        }
        *,63? {
            GridFtpProcessWrappedInput $fileId $chan
            set data(buffer) {}
        }
        default {
            log::log error "Unknown state $data(state),$data(rc)"
            log::log error $data(buffer)
            GridFtpQuit $chan
        }
    }
}

# -------------------------------------------------------------------------

proc GridFtpProcessWrappedInput {fileId chan} {
    global sbufCommands rbufCommands
    upvar #0 GridFtp$chan data

    set line $data(buffer)

    if {![regexp -- {^-?(\d+)( |-)?(.*)$} $line -> rc ml msg]} {
		    log::log error "Unsupported response from FTP server\n$line"
		    return
	  }

    set data(rc) $rc
    
    log::log debug $data(state),$data(rc)

    switch -glob -- $data(state),$data(rc) {
        login,200 -
        login,331 {
            puts $chan [$data(context) wrap {PASS dummy}]
            set data(state) pass
        }
        pass,200 -
        pass,230 {
            puts $chan [$data(context) wrap {TYPE I}]
            set data(state) type
        }
        type,200 {
            puts $chan [$data(context) wrap {MODE E}]
            set data(state) mode
        }
        mode,200 {
            puts $chan [$data(context) wrap {DCAU N}]
            set data(state) dcau
        }
        dcau,200 -
        dcau,500 -
        bufsize,500 {
            if {$data(stor)} {
                if {$data(bufcmd) >= [llength $sbufCommands]} {
                    log::log error "Failed to set STOR buffer size"
                    puts $chan [$data(context) wrap {PASV}]
                    set data(state) pasv
                    return
                }
                set command [lindex $sbufCommands $data(bufcmd)]
            } else {
                if {$data(bufcmd) >= [llength $rbufCommands]} {
                    log::log error "Failed to set RETR buffer size"
                    puts $chan [$data(context) wrap {OPTS RETR Parallelism=8,8,8;}]
                    set data(state) opts
                    return
                }
                set command [lindex $rbufCommands $data(bufcmd)]
            }
            puts $chan [$data(context) wrap "$command 1048576"]
            incr data(bufcmd)
            set data(state) bufsize
        }
        bufsize,200 {
            if {$data(stor)} {
                puts $chan [$data(context) wrap {PASV}]
                set data(state) pasv
            } else {
                puts $chan [$data(context) wrap {OPTS RETR Parallelism=8,8,8;}]
                set data(state) opts
            }
        }
        pasv,227 {
            regexp -- {\d+,\d+,\d+,\d+,\d+,\d+} $msg port
            GridFtpRetr $fileId $data(srcTURL) $port
            puts $chan [$data(context) wrap "STOR $data(file)"]
            set data(state) stor
        }
        opts,200 -
        opts,500 {
            puts $chan [$data(context) wrap "PORT $data(port)"]
            set data(state) port
        }
        port,200 {
            puts $chan [$data(context) wrap "RETR $data(file)"]
            set data(state) retr
        }
        stor,226 -
        retr,226 {
            SrmCopyDone $fileId
            puts $chan [$data(context) wrap {QUIT}]
            set data(state) quit
        }
        *,1?? -
        *,2?? {
            log::log debug $line
        }
        default {
            log::log error "Unknown state $data(state),$data(rc)"
            log::log error $data(buffer)
            GridFtpQuit $chan
        }
    }
}

# -------------------------------------------------------------------------

proc GridFtpQuit {chan} {
    upvar #0 GridFtp$chan data

    if {[file channels $chan] != {}} {
        puts $chan {QUIT}
    }

    if {[info exists data]} {
        set data(state) quit
        set data(afterId) [after 30000 [list GridFtpClose $chan]]
    }
}

# -------------------------------------------------------------------------

proc GridFtpClose {chan} {
    upvar #0 GridFtp$chan data

    log::log debug "GridFtpClose: [file channels $chan]"
    if {[file channels $chan] != {}} {
        fileevent $chan readable {}
        ::close $chan
        log::log debug "GridFtpClose: close $chan"
    }

    if {[info exists data]} {
        set context $data(context)
        if {[info proc $context] eq "$context" &&
            [string length $context] != 0} {
            $context destroy
        }
        
        set afterId $data(afterId)
        if {$afterId != {}} {
            after cancel $afterId
        }

        unset data
    }
}

# -------------------------------------------------------------------------

proc GridFtpRetr {fileId srcTURL port} {

    upvar #0 GridFtpIndex($fileId) index
    upvar #0 SrmFiles($fileId) file
    set certProxy [dict get $file certProxy]

    set hostfile [ExtractHostFile $srcTURL]

    set chan [socket [lindex $hostfile 0] 2811]
    fconfigure $chan -blocking 0 -translation {auto crlf} -buffering line
    fileevent $chan readable [list GridFtpGetInput $fileId $chan]
    
    lappend index $chan

    upvar #0 GridFtp$chan data

    set data(context) [gss::context $chan -gssimport $certProxy]
    set data(afterId) {}
    set data(buffer) {}
    set data(bufcmd) 0
    set data(state) new
    set data(stor) 0
    set data(port) $port
    set data(file) [lindex $hostfile 1]
}

# -------------------------------------------------------------------------

proc GridFtpStor {fileId dstTURL srcTURL} {

    upvar #0 GridFtpIndex($fileId) index
    upvar #0 SrmFiles($fileId) file
    set certProxy [dict get $file certProxy]

    set hostfile [ExtractHostFile $dstTURL]

    set chan [socket [lindex $hostfile 0] 2811]
    fconfigure $chan -blocking 0 -translation {auto crlf} -buffering line
    fileevent $chan readable [list GridFtpGetInput $fileId $chan]

    lappend index $chan

    upvar #0 GridFtp$chan data

    set data(context) [gss::context $chan -gssimport $certProxy]
    set data(afterId) {}
    set data(buffer) {}
    set data(bufcmd) 0
    set data(state) new
    set data(stor) 1
    set data(port) {}
    set data(file) [lindex $hostfile 1]
    set data(srcTURL) $srcTURL
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

proc GridFtpCopy {fileId srcTURL dstTURL} {

    GridFtpStor $fileId $dstTURL $srcTURL
}

# -------------------------------------------------------------------------

proc GridFtpStop {fileId} {
    upvar #0 GridFtpIndex($fileId) index

    if {![info exists index]} {
        log::log warning "GridFtpStop: Unknown file id $fileId"
        return
    }

    foreach indexChannel $index {
        GridFtpQuit $indexChannel
    }
    set index {}
}

# -------------------------------------------------------------------------

proc GridFtpFailed {fileId chan} {
    upvar #0 GridFtpIndex($fileId) index

    SrmFailed $fileId "Error during gridftp transfer"

    foreach indexChannel $index {
        if {[string equal $indexChannel $chan]} {
           GridFtpClose $indexChannel
        } else {
           GridFtpQuit $indexChannel
        }
    }
    set index {}
}

# -------------------------------------------------------------------------

package provide srmlite::gridftp 0.1
