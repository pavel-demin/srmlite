
package require Tclx

# -------------------------------------------------------------------------

proc ExtractHostFile {url} {

    set exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:([0-9]+))?(/srm/managerv1\?SFN=)?(/.*)?$}
    if {![regexp -nocase $exp $url x prefix proto user host y port z file]} {
        log::log error "Unsupported URL $url"
        return {}
    }

    set file [file normalize $file]

    append host { } $file
    return $host
}

# -------------------------------------------------------------------------

proc SrmGet {requestType fileId userName SURL} {

    set command "./setuid $userName ./url_get.sh [ExtractHostFile $SURL]"
#    set command "./url_get.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $fileId {} $command
}

# -------------------------------------------------------------------------

proc SrmPut {requestType fileId userName SURL} {

    set command "./setuid $userName ./url_put.sh [ExtractHostFile $SURL]"
#    set command "./url_put.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $fileId {} $command
}

# -------------------------------------------------------------------------

proc SrmCopy {requestType fileId userName certProxy srcTURL dstTURL} {

    set certProxyCopy $certProxy
    append certProxyCopy {.copy}
    file copy $certProxy $certProxyCopy
    chown $userName $certProxyCopy

    set command "./setuid $userName ./url_copy.sh [ExtractHostFile $srcTURL] [ExtractHostFile $dstTURL] $certProxyCopy"
#    set command "./url_copy.sh [ExtractHostFile $srcTURL] [ExtractHostFile $dstTURL] $certProxyCopy"

    SubmitCommand $requestType $fileId $certProxyCopy $command
}

# -------------------------------------------------------------------------


proc SrmStop {requestType fileId} {

    global State SrmProcessIndex

    if {[info exists SrmProcessIndex($fileId)]} {
        set processId $SrmProcessIndex($fileId)

        KillCommand $processId

    } else {
        set faultString "Unknown file ID $fileId"
        log::log error $faultString
        puts $State(out) [list Failed {} $fileId $faultString]
    }
}

# -------------------------------------------------------------------------

proc KillCommand {processId} {

    upvar #0 SrmProcesses($processId) process
    upvar #0 SrmProcessTimer($processId) timer

    set fileId [dict get $process fileId]
    upvar #0 SrmProcessIndex($fileId) index

    set certProxy [dict get $process certProxy]

    if {[info exists index]} {
        unset index
    }

    if {[info exists timer]} {
        unset timer
    }

    if {[catch {kill $processId} message]} {
        log::log debug $message
    } elseif {[catch {kill 1 $processId} message]} {
        log::log debug $message
    } elseif {[catch {kill 9 $processId} message]} {
        log::log debug $message
    }

    if {[file exists $certProxy]} {
        file delete $certProxy
    }
}

# -------------------------------------------------------------------------

proc SubmitCommand {requestType fileId certProxy command} {

    global State

    log::log debug $command

    if {[catch {open "| $command" {RDONLY NONBLOCK}} pipe]} {
        set faultString "Failed to execute '$command'"
        log::log error $faultString
        puts $State(out) [list Failed $requestType $fileId $faultString]
        return
    }

    set processId [pid $pipe]
    log::log debug "\[process: $processId\] $command"

    upvar #0 SrmProcesses($processId) process
    upvar #0 SrmProcessTimer($processId) timer
    upvar #0 SrmProcessIndex($fileId) index

    set process [dict create requestType $requestType fileId $fileId \
        certProxy $certProxy output {}]
    set index $processId
    set timer -1

    fconfigure $pipe -buffering none -blocking 0
    fileevent $pipe readable [list GetCommandOutput $processId $pipe]
}

# -------------------------------------------------------------------------

proc Timeout {seconds} {
    global SrmProcessTimer

    log::log debug "Timeout $seconds"

    foreach processId [array names SrmProcessTimer] {
        set counter [incr SrmProcessTimer($processId)]
        log::log debug "\[process: $processId\] $counter"
        if {$counter > 5} {
            after 0 [list KillCommand $processId]
        }
    }
    alarm $seconds
}

# -------------------------------------------------------------------------

proc GetCommandOutput {processId pipe} {

    upvar #0 SrmProcesses($processId) process

    if {[catch {gets $pipe line} readCount]} {
        log::log error $readCount
        Finish $processId $pipe
        return
    }

    if {$readCount == -1} {
        if {[eof $pipe]} {
            Finish $processId $pipe
        } else {
            log::log warning "\[process: $processId\] No full line available, retrying..."
        }
        return
    }

    if {$line != {}} {
        dict set process output $line
        log::log debug "+> $line"
    }
}

# -------------------------------------------------------------------------

proc Finish {processId pipe} {

    global State
    upvar #0 SrmProcesses($processId) process
    upvar #0 SrmProcessTimer($processId) timer

    set hadError 0
    if {[file channels $pipe] != {}} {

        fileevent $pipe readable {}
        fconfigure $pipe -blocking 1

        if {[catch {close $pipe} result]} {
            set hadError 1
            log::log error $result
            log::log error [dict get $process output]
        }
    }

    if {[info exists timer]} {
        unset timer
    }

    dict with process {

        if {$hadError} {
            set state Failed
        } elseif {[string equal $requestType copy]} {
            set state Done
        } else {
            set state Ready
        }

        puts $State(out) [list $state $requestType $fileId $output]
    }

    unset process

}

# -------------------------------------------------------------------------

proc GetInput {chan} {

    global State

    if {[catch {gets $chan line} readCount]} {
        log::log error $readCount
        close $chan
        return
    }

    if {$readCount == -1} {
        if {[eof $chan]} {
            log::log error {Broken connection fetching request}
            close $chan
        } else {
            log::log warning {No full line available, retrying...}
        }
        return
    }

    log::log debug $line

    set requestType [lindex $line 0]

    switch -- $requestType {
        get {
            eval SrmGet $line
        }
        put {
            eval SrmPut $line
        }
        copy {
            eval SrmCopy $line
        }
        stop {
            eval SrmStop $line
        }
        default {
            log::log error "Unknown request type $requestType"
        }
    }
}

# -------------------------------------------------------------------------

package provide srmlite::backend 0.1
