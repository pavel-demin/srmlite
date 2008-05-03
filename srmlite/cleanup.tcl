package require log
package require dict
package require Tclx
package require XOTcl

package require srmlite::utilities

namespace eval ::srmlite::cleanup {
    namespace import ::xotcl::*
    namespace import ::srmlite::utilities::LogRotate

    Class CleanupService -parameter {
        {logFile}
    }

# -------------------------------------------------------------------------

    CleanupService instproc init {} {
        my set objectDict [dict create]
    }

# -------------------------------------------------------------------------

    CleanupService instproc addObject {obj} {
        my instvar objectDict
        dict set objectDict $obj 0
    }

# -------------------------------------------------------------------------

    CleanupService instproc removeObject {obj} {
        my instvar objectDict
        if {[dict exists $objectDict $obj]} {
            dict unset objectDict $obj
        }
    }

# -------------------------------------------------------------------------

    CleanupService instproc timeout {seconds} {
        my instvar objectDict

        log::log debug "cleanup $seconds"

        LogRotate [my logFile]

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

package provide srmlite::cleanup 0.1
