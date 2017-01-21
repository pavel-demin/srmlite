package require log
package require Tclx
package require TclOO

package require srmlite::utilities

namespace eval ::srmlite::cleanup {
    namespace import ::srmlite::utilities::LogRotate

# -------------------------------------------------------------------------

    oo::class create CleanupService

# -------------------------------------------------------------------------

    oo::define CleanupService constructor args {
        my variable logFile objectDict

        foreach {param value} $args {
            if {$param eq "-logFile"} {
                set logFile $value
            } else {
                error "unsupported parameter $param"
            }
        }

        set objectDict [dict create]
    }

# -------------------------------------------------------------------------

    oo::define CleanupService method addObject {obj} {
        my variable objectDict
        dict set objectDict $obj 0
    }

# -------------------------------------------------------------------------

    oo::define CleanupService method removeObject {obj} {
        my variable objectDict
        if {[dict exists $objectDict $obj]} {
            dict unset objectDict $obj
        }
    }

# -------------------------------------------------------------------------

    oo::define CleanupService method timeout {seconds} {
        my variable logFile objectDict

        log::log debug "cleanup $seconds"

        LogRotate $logFile

        dict for {obj counter} $objectDict {
            dict incr objectDict $obj
            if {$counter > 15} {
                if {[Object isobject $obj]} {
                    after 0 [list $obj destroy]
                }
                dict unset objectDict $obj
            }
        }

        alarm $seconds
    }

# -------------------------------------------------------------------------

    namespace export CleanupService
}

package provide srmlite::cleanup 0.2
