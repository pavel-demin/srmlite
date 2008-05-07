
package require log

package require XOTcl

namespace eval ::srmlite::frontend {
    namespace import ::xotcl::*

    Class FrontendService -parameter {
        {in stdin}
        {out stdout}
    }

# -------------------------------------------------------------------------

    FrontendService instproc log {level args} {
        log::log $level [join $args { }]
    }


# -------------------------------------------------------------------------

    FrontendService instproc init {} {
        my instvar in out
        fconfigure $in -blocking false -buffering line
        fconfigure $out -blocking false -buffering line
        fileevent $in readable [myproc GetInput]
        next
    }

# -------------------------------------------------------------------------

    FrontendService instproc process {arg} {
        puts [my out] $arg
    }

# -------------------------------------------------------------------------

    FrontendService instproc GetInput {} {

        variable permDict

        if {[my getLine line] < 0} {
            return
        }

        my log notice $line

        set state [lindex $line 0]
        set prefix [lindex $line 1]
        set obj [lindex $line 2]
        set output [lindex $line 3]

        if {[Object isobject $obj]} {
            after 0 [list $obj $prefix$state $output]
        }
    }

# -------------------------------------------------------------------------

    FrontendService instproc getLine {var} {
        my upvar $var line
        my instvar in

        if {[catch {gets $in line} readCount]} {
            my log error "Error during gets: $readCount"
            my close
            return -2
        }

        if {$readCount == -1} {
            if {[eof $in]} {
                my log error {Broken connection}
                my close
                return -2
            } else {
                my log warning {No full line available, retrying...}
                return -1
            }
        }

        return $readCount
    }

# -------------------------------------------------------------------------

    FrontendService instproc close {} {
        my instvar in
        if {[my exists in]} {
            catch {
                fileevent $in readable {}
                fileevent $in writable {}
                ::close $in
                unset in
            }
    	}
    }
# -------------------------------------------------------------------------

    namespace export FrontendService
}

package provide srmlite::frontend 0.1
