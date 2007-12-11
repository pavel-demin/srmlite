
package require Tclx
package require dict

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

proc SrmAdvisoryDelete {requestType fileId userName SURL} {

    set command "./setuid $userName ./url_del.sh [ExtractHostFile $SURL]"
#    set command "./url_put.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $fileId {} $command
}

# -------------------------------------------------------------------------

proc SubmitCommand {requestType fileId certProxy command} {

    global State

    log::log debug $command

    if {[catch {open "| $command" {RDONLY NONBLOCK}} pipe]} {
        set faultString "Failed to execute '$command'"
        log::log error $faultString
        log::log error $pipe
        puts $State(out) [list Failed $requestType $fileId $faultString]
        return
    }

    set processId [pid $pipe]
    log::log debug "\[process: $processId\] $command"

    upvar #0 SrmProcesses($processId) process

    set process [dict create requestType $requestType fileId $fileId \
        certProxy $certProxy output {}]

    fconfigure $pipe -buffering none -blocking 0
    fileevent $pipe readable [list GetCommandOutput $requestType $fileId $processId $pipe]
}

# -------------------------------------------------------------------------

proc GetCommandOutput {requestType fileId processId pipe} {

    upvar #0 SrmProcesses($processId) process

    if {[catch {gets $pipe line} readCount]} {
        log::log error $readCount
        Finish $requestType $fileId $processId $pipe
        return
    }

    if {$readCount == -1} {
        if {[eof $pipe]} {
            Finish $requestType $fileId $processId $pipe
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

proc Finish {requestType fileId processId pipe} {

    global State
    upvar #0 SrmProcesses($processId) process

    set hadError 0
    if {[file channels $pipe] != {}} {

        fileevent $pipe readable {}
        fconfigure $pipe -blocking 1

        if {[catch {close $pipe} result]} {
            set hadError 1
            log::log error $result
        }
    }

    if {$hadError} {
        set state Failed
    } elseif {[string equal $requestType copy]} {
        set state Done
    } else {
        set state Ready
    }

    set output {}

    if {[info exists process]} {
        set output [dict get $process output]
        set certProxy [dict get $process certProxy]
        if {[file exists $certProxy]} {
            file delete $certProxy
        }
        unset process
    }

    puts $State(out) [list $state $requestType $fileId $output]
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
        advisoryDelete {
            eval SrmAdvisoryDelete $line
        }
        default {
            log::log error "Unknown request type $requestType"
        }
    }
}

# -------------------------------------------------------------------------

package provide srmlite::backend 0.1
