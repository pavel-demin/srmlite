package require Tclx

package require srmlite::utilities
namespace import ::srmlite::utilities::LogRotate

# -------------------------------------------------------------------------

array set State {
    in stdout
    out stdin
}

set QueueSize 0
set QueueData [list]

# -------------------------------------------------------------------------

proc ExtractHostFile {url} {

    set exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:(\d+))?(/srm/managerv\d\?SFN=)?(/.*)?$}
    if {![regexp -nocase $exp $url x prefix proto user host y port z file]} {
        log::log error "Unsupported URL $url"
        return {}
    }

    set file [file normalize $file]

    append host { } $file
    return $host
}

# -------------------------------------------------------------------------

proc SrmLs {requestType uniqueId userName depth SURL} {

    set command "./setuser $userName ./scripts/url_ls.sh $depth [ExtractHostFile $SURL]"
#    set command "./scripts/url_ls.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $uniqueId $command
}

# -------------------------------------------------------------------------

proc SrmGet {requestType uniqueId userName SURL} {

    set command "./setuser $userName ./scripts/url_get.sh [ExtractHostFile $SURL]"
#    set command "./scripts/url_get.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $uniqueId $command
}

# -------------------------------------------------------------------------

proc SrmPut {requestType uniqueId userName SURL} {

    set command "./setuser $userName ./scripts/url_put.sh [ExtractHostFile $SURL]"
#    set command "./scripts/url_put.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $uniqueId $command
}

# -------------------------------------------------------------------------

proc SrmRm {requestType uniqueId userName SURL} {

    set command "./setuser $userName ./scripts/url_del.sh [ExtractHostFile $SURL]"
#    set command "./scripts/url_del.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $uniqueId $command
}

# -------------------------------------------------------------------------

proc SrmMkdir {requestType uniqueId userName SURL} {

    set command "./setuser $userName ./scripts/url_mkdir.sh [ExtractHostFile $SURL]"
#    set command "./scripts/url_mkdir.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $uniqueId $command
}

# -------------------------------------------------------------------------

proc SrmRmdir {requestType uniqueId userName SURL} {

    set command "./setuser $userName ./scripts/url_rmdir.sh [ExtractHostFile $SURL]"
#    set command "./scripts/url_mkdir.sh [ExtractHostFile $SURL]"
    SubmitCommand $requestType $uniqueId $command
}

# -------------------------------------------------------------------------

proc SrmAuth {requestType uniqueId gssContext} {

    set command "./scripts/getuser.sh $gssContext"
    SubmitCommand $requestType $uniqueId $command
}

# -------------------------------------------------------------------------

proc SubmitCommand {requestType uniqueId command} {

    global State

    log::log debug $command

    if {[catch {open "| $command" {RDONLY NONBLOCK}} pipe]} {
        set faultString "Failed to execute '$command'"
        log::log error $faultString
        log::log error $pipe
        puts $State(out) [list Failure $requestType $uniqueId $faultString]
        return
    }

    set processId [pid $pipe]
    log::log notice "\[process: $processId\] $command"

    upvar #0 SrmProcesses($processId) process

    set process [dict create requestType $requestType uniqueId $uniqueId output {}]

    fconfigure $pipe -buffering none -blocking 0
    fileevent $pipe readable [list GetCommandOutput $requestType $uniqueId $processId $pipe]
}

# -------------------------------------------------------------------------

proc GetCommandOutput {requestType uniqueId processId pipe} {

    upvar #0 SrmProcesses($processId) process

    if {[catch {gets $pipe line} readCount]} {
        log::log error $readCount
        Finish $requestType $uniqueId $processId $pipe
        return
    }

    if {$readCount == -1} {
        if {[eof $pipe]} {
            Finish $requestType $uniqueId $processId $pipe
        } else {
            log::log warning "\[process: $processId\] No full line available, retrying..."
        }
        return
    }

    if {$line != {}} {
        dict lappend process output $line
        log::log debug "+> $line"
    }
}

# -------------------------------------------------------------------------

proc Finish {requestType uniqueId processId pipe} {

    global State QueueSize QueueData errorCode
    upvar #0 SrmProcesses($processId) process

    set hadError 0
    if {[file channels $pipe] != {}} {

        fileevent $pipe readable {}
        fconfigure $pipe -blocking 1

        if {[catch {close $pipe} result]} {
            set hadError 1
            log::log error $result
            log::log error $errorCode
        }
    }

    if {$hadError} {
        set state Failure
    } else {
        set state Success
    }

    set output {}

    if {[info exists process]} {
        set output [dict get $process output]
        unset process
    }
    
    incr QueueSize -1

    if {$QueueSize < 10 && [llength $QueueData] > 0} {
        set line [lindex $QueueData 0]
        set QueueData [lreplace $QueueData [set QueueData 0] 0]
        Start $line
    }
    
    puts $State(out) [list $state $requestType $uniqueId $output]
}

# -------------------------------------------------------------------------

proc Timeout {seconds} {

    global Cfg

    log::log debug "Timeout $seconds"

    LogRotate $Cfg(backendLog)

    alarm $seconds
}

# -------------------------------------------------------------------------

proc GetInput {chan} {

    global State QueueSize QueueData

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
    
    if {$QueueSize < 10} {
        Start $line
    } else {
        lappend QueueData $line
    }
}

# -------------------------------------------------------------------------

proc Start {line} {

    global QueueSize QueueData

    set requestType [lindex $line 0]

    switch -- $requestType {
        get {
            eval SrmGet $line
        }
        put {
            eval SrmPut $line
        }
        rm {
            eval SrmRm $line
        }
        ls {
            eval SrmLs $line
        }
        mkdir {
            eval SrmMkdir $line
        }
        rmdir {
            eval SrmRmdir $line
        }
        authorization {
            eval SrmAuth $line
        }
        default {
            log::log error "Unknown request type $requestType"
        }
    }
    
    incr QueueSize
}

# -------------------------------------------------------------------------

package provide srmlite::backend 0.2

