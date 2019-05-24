lappend auto_path .

package require Tclx
package require log

package require srmlite::cfg

# -------------------------------------------------------------------------

proc ::log::Puts {level text} {
    variable channelMap
    variable fill

    set chan $channelMap($level)
    if {$chan eq {}} {
        # Ignore levels without channel.
        return
    }

    chan puts $chan "$text"
    return
}

# -------------------------------------------------------------------------

proc SetLogLevel {level} {
    log::lvSuppressLE emergency 0
    log::lvSuppressLE $level 1
    log::lvSuppress $level 0
}

# -------------------------------------------------------------------------

proc FormatLogMessage {level message} {
    set time [clock format [clock seconds] -format {%a %b %d %H:%M:%S %Y}]
    log::Puts $level "\[$time] \[$level\] $message"
}


# -------------------------------------------------------------------------

proc SetupTimer {seconds command} {
    signal unblock {ALRM}
    signal -restart trap {ALRM} $command
    alarm $seconds
}

# -------------------------------------------------------------------------

proc Shutdown {} {
  # whatever cleanup you need to do

  log::log notice "Shutting down process [pid]..."

  exit
}

# -------------------------------------------------------------------------

proc StartFrontend {pipein pipeout} {

    global Cfg

    package require srmlite::http::server
    namespace import ::srmlite::http::server::*

    package require srmlite::cleanup
    namespace import ::srmlite::cleanup::*

    package require srmlite::frontend
    namespace import ::srmlite::frontend::*

    package require srmlite::srm::server
    namespace import ::srmlite::srm::server::*

    package require srmlite::utilities

    id group $Cfg(frontendGroup)
    id user $Cfg(frontendUser)

    set fid [open $Cfg(frontendLog) w]
    chan configure $fid -blocking 0 -buffering line -buffersize 32768
    log::lvChannelForall $fid

    set ::srmlite::utilities::logFileId $fid

    set ::srmlite::utilities::getHosts $Cfg(getHosts)
    set ::srmlite::utilities::putHosts $Cfg(putHosts)

    log::log notice "frontend started with pid [pid]"
#    close $fid

    CleanupService timeout \
        -logFile $Cfg(frontendLog)

    FrontendService frontend \
        -in [lindex $pipeout 0] \
        -out [lindex $pipein 1]

    SrmManager manager \
        -cleanupService timeout \
        -frontendService frontend

    HttpServer server \
        -port $Cfg(frontendPort) \
        -frontendService frontend

    server exportObject -prefix $Cfg(srmPrefix) -object manager

    server start

    log::log notice "starting httpd server on port $Cfg(frontendPort)"

    SetupTimer 600 [list timeout timeout 600]

    # start the Tcl event loop
    vwait forever

    Shutdown
}

# -------------------------------------------------------------------------

proc StartBackend {pipein pipeout} {

    package require srmlite::backend
    package require srmlite::utilities

    global Cfg State

    set fid [open $Cfg(backendLog) w]
    chan configure $fid -blocking 0 -buffering line -buffersize 32768
    log::lvChannelForall $fid

    set ::srmlite::utilities::logFileId $fid

    log::log notice "backend started with pid [pid]"
#    close $fid

    set State(in) [lindex $pipein 0]
    set State(out) [lindex $pipeout 1]

    chan configure $State(in) -blocking 0 -buffering line -buffersize 32768
    chan configure $State(out) -blocking 0 -buffering line -buffersize 32768

    chan event $State(in) readable [list GetInput $State(in)]

    SetupTimer 600 [list Timeout 600]

    # start the Tcl event loop
    vwait forever

    Shutdown
}

# -------------------------------------------------------------------------

proc bgerror {msg} {
    global errorInfo
    log::log error "bgerror: $msg"
    log::log error "bgerror: $errorInfo"
}

# -------------------------------------------------------------------------

proc Daemonize {} {
    close stdin
    close stdout
    close stderr
    if {[fork]} {exit 0}
    id process group set
    if {[fork]} {exit 0}
    set fid [open /dev/null r]
    set fid [open /dev/null w]
    set fid [open /dev/null w]
    cd /
    umask 022
    return [id process]
}

# -------------------------------------------------------------------------

if {[llength $argv] != 1} {
    puts {Usage: srmlite config_file}
    puts {   config_file - connfiguration file}
    exit 1
}

log::lvCmdForall FormatLogMessage
SetLogLevel notice

set fileName [lindex $argv 0]

if {[catch {ValidateFile $fileName} result]} {
    log::log error $result
    exit 1
} else {

    set fileSizeMax 8192

    if {[file size $fileName] > $fileSizeMax} {
        log::log error "$fileName is too big for a configuration file"
        exit 1
    }

    if {[catch {open $fileName} result]} {
        log::log error $result
        exit 1
    }

    set content [read $result $fileSizeMax]
    close $result

    if {[catch {CfgParser $content} result]} {
        log::log error $result
        exit 1
    }
}

if {[catch {CfgValidate} result]} {
    log::log error $result
    exit 1
}

SetLogLevel $Cfg(logLevel)

#    cd $Cfg(workDir)
#    chroot $Cfg(chrootDir)


#Daemonize
signal ignore  SIGHUP
signal unblock {INT QUIT TERM}
signal -restart trap {INT QUIT TERM} Shutdown


set pipein [pipe]
set pipeout [pipe]

switch [fork] {
    -1 {
        Shutdown
    }
    0 {
        StartFrontend $pipein $pipeout
    }
    default {
        StartBackend $pipein $pipeout
    }
}

