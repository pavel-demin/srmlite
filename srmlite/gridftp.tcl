
package require gss::context
package require dict
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
        SrmFailed $fileId "Error during gridftp transfer"
        return
    }

    if {$readCount == -1} {
        if {[eof $chan]} {
            set state $data(state)
            GridFtpClose $fileId $chan
            if {$state != "quit"} {
                log::log error "$prefix Broken connection during gridftp transfer"
                GridFtpStop $fileId
                SrmFailed $fileId "$prefix Error during gridftp transfer"
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
                SrmFailed $fileId "Error during unwrap"
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

    GridFtpProcessClearInput $fileId $chan
}

# -------------------------------------------------------------------------

proc GridFtpHandshake {fileId chan msg} {

    upvar #0 GridFtp$chan data

    if {[catch {$data(context) handshake $msg} result]} {
        GridFtpClose $fileId $chan
        GridFtpStop $fileId
        SrmFailed $fileId "Error during handshake"
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
        SrmFailed $fileId "Error during wrap"
    } else {
        puts $chan $result
    }
}

# -------------------------------------------------------------------------

proc GridFtpProcessClearInput {fileId chan} {

    upvar #0 GridFtp$chan data

    set prefix "\[fileId $fileId\] \[server $data(host)\]"

    log::log debug "$prefix $data(state),$data(rc)"

    switch -glob -- $data(state),$data(rc) {
        new,220 {
            puts $chan {AUTH GSSAPI}
            set data(state) auth
            set data(buffer) {}
        }
        auth,334 {
            GridFtpHandshake $fileId $chan {}
            set data(state) handshake
            set data(buffer) {}
        }
        handshake,335 {
            GridFtpHandshake $fileId $chan $data(buffer)
            set data(state) handshake
            set data(buffer) {}
        }
        handshake,235 {
            GridFtpWrap $fileId $chan {USER :globus-mapping:}
            set data(state) login
            set data(buffer) {}
        }
        quit,* {
            GridFtpClose $fileId $chan
        }
        *,63? {
            GridFtpProcessWrappedInput $fileId $chan
            set data(buffer) {}
        }
        default {
            log::log error "$prefix Unknown state $data(state),$data(rc)"
            log::log error "$prefix $data(buffer)"
            GridFtpStop $fileId
            SrmFailed $fileId $data(buffer)
        }
    }
}

# -------------------------------------------------------------------------

proc GridFtpProcessWrappedInput {fileId chan} {
    global sbufCommands rbufCommands
    upvar #0 GridFtp$chan data

    set prefix "\[fileId $fileId\] \[server $data(host)\]"

    set line $data(buffer)

    if {![regexp -- {^-?(\d+)( |-)?(.*)$} $line -> rc ml msg]} {
        log::log error "$prefix Unsupported response from FTP server\n$line"
        return
    }

    set data(rc) $rc
    
    log::log debug "$prefix $data(state),$data(rc)"

    switch -glob -- $data(state),$data(rc) {
        login,200 -
        login,331 {
            GridFtpWrap $fileId $chan {PASS dummy}
            set data(state) pass
        }
        pass,200 -
        pass,230 {
            GridFtpWrap $fileId $chan {TYPE I}
            set data(state) type
        }
        type,200 {
            GridFtpWrap $fileId $chan {MODE E}
            set data(state) mode
        }
        mode,200 {
            GridFtpWrap $fileId $chan {DCAU N}
            set data(state) dcau
        }
        dcau,200 -
        dcau,500 -
        bufsize,500 {
            if {$data(stor)} {
                if {$data(bufcmd) >= [llength $sbufCommands]} {
                    log::log error "$prefix Failed to set STOR buffer size"
                    GridFtpWrap $fileId $chan {PASV}
                    set data(state) pasv
                    return
                }
                set command [lindex $sbufCommands $data(bufcmd)]
            } else {
                if {$data(bufcmd) >= [llength $rbufCommands]} {
                    log::log error "$prefix Failed to set RETR buffer size"
                    GridFtpWrap $fileId $chan {OPTS RETR Parallelism=8,8,8;}
                    set data(state) opts
                    return
                }
                set command [lindex $rbufCommands $data(bufcmd)]
            }
            GridFtpWrap $fileId $chan "$command 1048576"
            incr data(bufcmd)
            set data(state) bufsize
        }
        bufsize,200 {
            if {$data(stor)} {
                GridFtpWrap $fileId $chan {PASV}
                set data(state) pasv
            } else {
                GridFtpWrap $fileId $chan {OPTS RETR Parallelism=8,8,8;}
                set data(state) opts
            }
        }
        pasv,227 {
            regexp -- {\d+,\d+,\d+,\d+,\d+,\d+} $msg port
            GridFtpWrap $fileId $chan "STOR $data(file)"
            set data(state) stor
            GridFtpRetr $fileId $data(srcTURL) $port
        }
        opts,200 -
        opts,500 {
            GridFtpWrap $fileId $chan "PORT $data(port)"
            set data(state) port
        }
        port,200 {
            GridFtpWrap $fileId $chan "RETR $data(file)"
            set data(state) retr
        }
        retr,226 {
            log::log debug "$prefix $line"
        }
        stor,226 {
            log::log debug "$prefix $line"
            GridFtpQuit $fileId $chan QUIT
            GridFtpStop $fileId
            SrmCopyDone $fileId
        }
        *,1?? -
        *,2?? {
            log::log debug "$prefix [lindex [split $line "\n"] 0]"
        }
        default {
            log::log error "$prefix Unknown state $data(state),$data(rc)"
            log::log error "$prefix $data(buffer)"
            GridFtpStop $fileId
            SrmFailed $fileId $data(buffer)
        }
    }
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
    set data(state) new
    set data(stor) 0
    set data(port) $port
    set data(host) [lindex $hostfile 0]
    set data(file) [lindex $hostfile 1]

    set prefix "\[fileId $fileId\] \[server $data(host)\]"
    log::log debug "$prefix GridFtpCopy: import $data(context)"
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
    set data(state) new
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

package provide srmlite::gridftp 0.1
