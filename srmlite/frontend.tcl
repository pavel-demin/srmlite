package require log
package require TclOO

proc ::oo::Helpers::mymethod {method args} {
  list [uplevel 1 {namespace which my}] $method {*}$args
}

namespace eval ::srmlite::frontend {

# -------------------------------------------------------------------------

    oo::class create FrontendService

# -------------------------------------------------------------------------

    oo::define FrontendService constructor args {
        my variable in out

        set in stdin
        set out stdout

        foreach {param value} $args {
            if {$param eq "-in"} {
                set in $value
            } elseif {$param eq "-out"} {
                set out $value
            } else {
                error "unsupported parameter $param"
            }
        }

        fconfigure $in -blocking false -buffering line
        fconfigure $out -blocking false -buffering line
        fileevent $in readable [mymethod GetInput]
    }

# -------------------------------------------------------------------------

    oo::define FrontendService method log {level args} {
        log::log $level [join $args { }]
    }

# -------------------------------------------------------------------------

    oo::define FrontendService method process {arg} {
        my variable out
        puts $out $arg
    }

# -------------------------------------------------------------------------

    oo::define FrontendService method GetInput {} {
        my variable in

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

    oo::define FrontendService method close {} {
        my variable in
        if {[info exists in]} {
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

package provide srmlite::frontend 0.2
