
lappend auto_path .

package require Tclx
package require log

package require srmlite::cfg

# -------------------------------------------------------------------------

array set State {
    requestId -2147483648
    in stdout
    out stdin
}

# -------------------------------------------------------------------------

proc ::log::Puts {level text} {
    variable channelMap
    variable fill

    set chan $channelMap($level)
    if {$chan == {}} {
        # Ignore levels without channel.
        return
    }

    puts $chan "$text"
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

proc shutdown {} {
  # whatever cleanup you need to do

  log::log notice "Shutting down process [pid]..."

  exit
}

# -------------------------------------------------------------------------

proc frontend {} {

    global Cfg State

    package require srmlite::httpd
    package require srmlite::frontend

    set State(ftpHosts) $Cfg(ftpHosts)

    id group $Cfg(frontendGroup)
    id user $Cfg(frontendUser)

    set ::env(GRIDMAP) $Cfg(gridMapFile)
    set ::env(GRIDMAPDIR) $Cfg(gridMapDir)

    set fid [open $Cfg(frontendLog) w]
    fconfigure $fid -blocking 0 -buffering line
    log::lvChannelForall $fid

    log::log notice "frontend started with pid [pid]"
#    close $fid

    set State(in) [lindex $State(pipein) 1]
    set State(out) [lindex $State(pipeout) 0]

    fconfigure $State(in) -blocking 0 -buffering line
    fconfigure $State(out) -blocking 0 -buffering line

    fileevent $State(out) readable [list GetInput $State(out)]

    HttpdServer . $Cfg(frontendPort) index.html

    log::log notice "starting httpd server on port $Cfg(frontendPort)"

    SetupTimer 600 [list SrmTimeout 600]

    # start the Tcl event loop
    vwait forever

    shutdown
}

# -------------------------------------------------------------------------

proc backend {} {

    global Cfg State

    package require srmlite::backend

    set fid [open $Cfg(backendLog) w]
    fconfigure $fid -blocking 0 -buffering line
    log::lvChannelForall $fid

    log::log notice "backend started with pid [pid]"
#    close $fid

    set State(in) [lindex $State(pipein) 0]
    set State(out) [lindex $State(pipeout) 1]

    fconfigure $State(in) -blocking 0 -buffering line
    fconfigure $State(out) -blocking 0 -buffering line

    fileevent $State(in) readable [list GetInput $State(in)]

    # start the Tcl event loop
    vwait forever

    shutdown
}

# -------------------------------------------------------------------------

proc bgerror {msg} {
    global errorInfo
    log::log error "bgerror: $msg"
    log::log error "bgerror: $errorInfo"
}

# -------------------------------------------------------------------------

proc daemonize {} {
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


#daemonize
signal ignore  SIGHUP
signal unblock {INT QUIT TERM}
signal -restart trap {INT QUIT TERM} shutdown


set State(pipein) [pipe]
set State(pipeout) [pipe]

switch [fork] {
    -1 {
        shutdown
    }
    0 {
        frontend
    }
    default {
        backend
    }
}

