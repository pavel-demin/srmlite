
package require Tclx
package require starfish

# -------------------------------------------------------------------------

array set CfgValidators {
    logLevel ValidateLogLevel
    ftpHosts ValidateFtpHosts
    chrootDir ValidateChrootDir
    daemonize ValidateBoolean
    frontendUser ValidateUser
    frontendPort ValidatePort
    frontendLog ValidateFrontendLog
    backendLog ValidateBackendLog
    gridMapDir ValidateGridMapDir
    gridMapFile ValidateGridMapFile
    srmv1Prefix ValidateEverything
    srmv2Prefix ValidateEverything
}

array set Cfg {
    logLevel notice
    ftpHosts ingrid-phedex.cism.ucl.ac.be
    chrootDir .
    daemonize false
    frontendUser edguser
    frontendPort 8443
    frontendLog frontend.log
    backendLog backend.log
    gridMapDir /etc/grid-security/gridmapdir
    gridMapFile /etc/grid-security/grid-mapfile
    srmv1Prefix /srm/managerv1
    srmv2Prefix /srm/managerv2
}

# -------------------------------------------------------------------------

proc ValidateEverything {dummy} {
}

# -------------------------------------------------------------------------

proc ValidatePort {dummy} {
}

# -------------------------------------------------------------------------

proc ValidateChrootDir {dummy} {
}

# -------------------------------------------------------------------------

proc ValidateGridMapDir {dummy} {
}

# -------------------------------------------------------------------------

proc ValidateGridMapFile {dummy} {
}


# -------------------------------------------------------------------------

proc ValidateFrontendLog {dummy} {
}

# -------------------------------------------------------------------------

proc ValidateBackendLog {dummy} {
}

# -------------------------------------------------------------------------

proc ValidateFile {fileName} {

    if {![file exists $fileName]} {
        return -code error "file $fileName does not exists"
    } elseif {![file isfile $fileName]} {
        return -code error "$fileName is not a regular file"
    } elseif {![file readable $fileName]} {
        return -code error "file $fileName is not readable"
    }
}

# -------------------------------------------------------------------------

proc ValidateFtpHosts {ftpHosts} {

    foreach host $ftpHosts {
        if {[catch {::starfish::netdb hosts name $host} result] &&
            [catch {::starfish::netdb hosts address $host} result]} {
            return -code error $result
        }
    }
}

# -------------------------------------------------------------------------

proc ValidateBoolean {value} {
    if {[lsearch {true false} $value] == -1} {
        return -code error "unknown boolean value (should be true or false) in\n$data"
    }
}

# -------------------------------------------------------------------------

proc ValidateLogLevel {level} {
    if {[lsearch {error notice debug} $level] == -1} {
        return -code error "unknown log level (should be error, info or debug) in\n$data"
    }
}

# -------------------------------------------------------------------------

proc ValidateUser {user} {

    if {[catch {id convert user $user} result]} {
        return -code error "unknown user $user"
    }
}

# -------------------------------------------------------------------------

proc ValidateWorkDir {srmWorkDir} {

    if {![file exists $srmWorkDir]} {
        return -code error "$srmWorkDir does not exist"
    }

    if {![file isdirectory $srmWorkDir]} {
        return -code error "$srmWorkDir is not a directory"
    }
}

# -------------------------------------------------------------------------

proc CfgParser {content} {

    global Cfg CfgValidators

    set data {}

    foreach line [split $content \n] {

        set commentIndex [string first {#} $line]
        if {$commentIndex != -1} {
            set line [string replace $line $commentIndex end]
        }
        set line [string trim $line]
        if {[string equal $line {}]} continue

        append data $line { }

        if {[catch {lindex $data 0} name] && ![info complete $data]} {
            continue
        }

        if {[llength $data] != 2} {
            return -code error "syntax error (should be 'name value') in\n$data"
        }
        if {![info exists CfgValidators($name)]} {
            return -code error  "unknown parameter name $name in\n$data"
        }

        set Cfg($name) [lindex $data 1]

        set data {}
    }
}

# -------------------------------------------------------------------------

proc CfgValidate {} {

    global Cfg CfgValidators

    foreach name [array names Cfg] {
        if {[catch {$CfgValidators($name) $Cfg($name)} result]} {
            return -code error  "$result\nwhile validating\n$name $Cfg($name)"
        }
    }
}

# -------------------------------------------------------------------------

package provide srmlite::cfg 0.1
