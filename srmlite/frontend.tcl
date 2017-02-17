
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
        chan configure $in -blocking 0 -buffering line -buffersize 32768
        chan configure $out -blocking 0 -buffering line -buffersize 32768
        chan event $in readable [myproc GetInput]
        next
    }

# -------------------------------------------------------------------------

    FrontendService instproc process {arg} {
        puts [my out] $arg
    }

# -------------------------------------------------------------------------

    FrontendService instproc GetInput {} {
        my instvar in
        variable permDict

        if {[catch {chan gets $in line} readCount]} {
            my log error "Error during chan gets: $readCount"
            my close
            return
        }

        if {$readCount == -1} {
            if {[chan eof $in]} {
                my log error {Broken connection}
                my close
                return
            } else {
                my log warning {No full line available, retrying...}
                return
            }
        }

        if {$readCount < 0} {
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

    FrontendService instproc close {} {
        my instvar in
        if {[my exists in]} {
            catch {
                chan event $in readable {}
                chan event $in writable {}
                chan close $in
                unset in
            }
        }
    }

# -------------------------------------------------------------------------

    namespace export FrontendService
}

package provide srmlite::frontend 0.1
