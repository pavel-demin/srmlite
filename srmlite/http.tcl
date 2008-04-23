# XOTcl implementation for asynchronous HTTP and HTTPs requests
# author Gustaf Neumann, Stefan Sobernig, Pavel Demin
# creation-date 2008-04-21
# cvs-id $Id: http.tcl,v 1.2 2008-04-23 19:27:01 demin Exp $

package require srmlite::notifier

package require XOTcl

namespace eval ::srmlite::http {
    namespace import ::xotcl::*
    namespace import ::srmlite::notifier::*

    #
    # Defined classes
    #    1) HttpRequest
    #    2) Tls (mixin class)
    #    3) Gss (mixin class)
    #
    ######################
    #
    ######################
    #
    # 1 HttpRequest
    #
    # HttpRequest is a class for implementing asynchronous HTTP requests
    # without vwait. HttpRequest requires to provide a listener
    # or callback object that will be notified upon success or failure of
    # the request.
    #
    # The following example defines a listener object (a).
    # Then in the second step, the listener object is used in te
    # asynchronous request (b).
    #
    # (a) Create a listener/callback object. Provide the two needed methods,
    # one being invoked upon success (deliver),
    # the other upon failure or cancellation (done).
    #
    #    Object ::listener \
    #         -proc deliver {payload obj} {
    #             my log "Asynchronous request suceeded!"
    #         } -proc done {reason obj} {
    #             my log "Asynchronous request failed: $reason"
    #         }
    #
    # (b)    Create the actual asynchronous request object.
    # Make sure that you specify the previously created listener/callback
    # object as "request_manager" to the request object.
    #
    #    HttpRequest new \
    #         -url "https://oacs-dotlrn-conf2007.wu-wien.ac.at/conf2007/" \
    #         -request_manager ::listener
    #

    Class create HttpRequest -superclass Notifier \
        -parameter {
            {url}
            {protocol http}
            {host}
            {port}
            {path /}
            {accept */*}
            {type text/plain}
            {agent xohttp/0.1}
            {timeout 30000}
        }

    HttpRequest instproc log {level args} {
        my instvar host
        log::log $level "\[server $host\] [join $args { }]"
    }

    HttpRequest instproc set_default_port {protocol} {
        switch $protocol {
            http    {my set port 80}
            https {my set port 443}
            srm -
            httpg {my set port 8443}
        }
    }

    HttpRequest instproc parse_url {} {
        my instvar protocol url host port path
        if {[regexp {^(http|https|srm|httpg)://([^/]+)(/.*)?$} $url _ protocol host path]} {
            # Be friendly and allow strictly speaking invalid urls
            # like "http://www.openacs.org"    (no trailing slash)
            if {$path eq ""} {set path /}
            my set_default_port $protocol
            regexp {^([^:]+):(.*)$} $host _ host port
        } else {
            error "unsupported or invalid url '$url'"
        }
    }

    HttpRequest instproc open_connection {} {
        my instvar chan host port
        set chan [socket -async $host $port]
        fileevent $chan writable [list [self] open_connection_done]
    }

    HttpRequest instproc open_connection_done {} {
        my instvar chan
        fileevent $chan writable {}

        if {[catch {my send_request} err]} {
            my cancel "Error during send request: $err"
            return
        }
    }

    HttpRequest instproc set_encoding {
        {-translation {auto binary}}
        type} {
        #
        # for text, use translation with optional encodings, else set translation binary
        #
        if {[string match "text/*" $type]} {
            if {[regexp {charset=([^ ]+)$} $type _ encoding]} {
	fconfigure [my set chan] -translation $translation -encoding [string tolower $encoding]
            } else {
	fconfigure [my set chan] -translation $translation
            }
        } else {
            fconfigure [my set chan] -translation binary
        }
    }

    HttpRequest instproc init {} {
        my instvar host port protocol
        if {[my exists url]} {
            my parse_url
        } else {
            if {![info exists port]} {my set_default_port $protocol}
            if {![info exists host]} {
                error "either host or url must be specified"
            }
        }
        switch $protocol {
            https {
                package require tls
                if {[info command ::tls::import] eq ""} {
                    error "https requests require the Tcl module TLS to be installed\n\
                             See e.g. http://tls.sourceforge.net/"
                }
                #
                # Add HTTPs handling
                #
                my mixin add Tls
            }
            srm -
            httpg {
                package require gss::socket
                if {[info command ::gss::import] eq ""} {
                    error "httpg and srm requests require the Tcl module gss::socket to be installed\n\
                             See e.g. http://srmlite.googlecode.com/"
                }
                #
                # Add HTTPg/SRM handling
                #
                my mixin add Gss
            }
        }
    }

    HttpRequest instproc send {{-headers {}} {-query {}}} {
        my instvar host port protocol

        my set afterId [after [my set timeout] [self] cancel timeout]
        my set meta [list]
        my set data {}

        my set query $query
        my set headers $headers

        if {[catch {my open_connection} err]} {
            my cancel "Error during open connection: $err"
            return
        }
    }

    HttpRequest instproc send_request {} {
        my instvar chan query host port protocol

        fconfigure $chan -blocking false

        set method [expr {$query eq "" ? "GET" : "POST"}]
        puts $chan "$method [my path] HTTP/1.0"
        puts $chan "Accept: [my accept]"
        puts $chan "Host: $host"
        puts $chan "User-Agent: [my agent]"
        foreach {tag value} [my set headers] {
	#regsub -all \[\n\r\] $value {} value
	#set tag [string trim $tag]
            puts $chan "$tag: $value"
        }
        my $method
    }

    HttpRequest instproc GET {} {
        my instvar chan
        puts $chan ""
        my query_done
    }

    HttpRequest instproc POST {} {
        my instvar chan query
        puts $chan "Content-Type: [my type]"
        puts $chan "Content-Length: [string length $query]"
        puts $chan ""
        my set_encoding [my type]
        puts -nonewline $chan $query
        my query_done
    }

    HttpRequest instproc query_done {} {
        my instvar chan
        flush $chan
        fileevent $chan readable [list [self] first_line]
    }

    HttpRequest instproc getLine {var} {
        my upvar $var response
        my instvar chan

        if {[catch {gets $chan response} n]} {
                my log error $n
                return -2
        }

        if {$n == -1} {
                if {[eof $chan]} {
                        return -2
                } else {
                        my log warning "No full line available, retrying..."
                        return -1
                }
        }

        return $n
    }

    HttpRequest instproc first_line {} {
        my instvar chan status_code
        fconfigure $chan -translation crlf
        set n [my getLine response]
        switch -exact -- $n {
            -2 {
                my cancel "Broken connection during http transfer"
                return
            }
            -1 {
                return
            }
        }
        if {[regexp {^HTTP/([0-9.]+) +([0-9]+) *} $response _ \
                responseHttpVersion status_code]} {
            my first_line_done
        } else {
            my cancel "Unexpected response: $response"
        }
    }

    HttpRequest instproc first_line_done {} {
        fileevent [my set chan] readable [list [self] header]
    }

    HttpRequest instproc header {} {
        while {1} {
            set n [my getLine response]
            switch -exact -- $n {
	-2 {
	    my cancel "Broken connection during http transfer"
	    return
	}
	-1 {
	    continue
	}
	0 {
                    break
	}
	default {
	    if {[regexp -nocase {^content-length:(.+)$} $response _ length]} {
	        my set content_length [string trim $length]
	    } elseif {[regexp -nocase {^content-type:(.+)$} $response _ type]} {
	        my set type [string trim $type]
	    }
	    if {[regexp -nocase {^([^:]+): *(.+)$} $response _ key value]} {
	        my lappend meta [string tolower $key] $value
	    }
	}
            }
        }
        my header_done
    }

    HttpRequest instproc header_done {} {
        # we have received the header, including potentially the type of the returned data
        my set_encoding [my type]
        fileevent [my set chan] readable [list [self] data]
    }

    HttpRequest instproc data {} {
        my instvar chan

        if {[eof $chan]} {
            my data_done
        } elseif {[catch {read $chan} block]} {
            my cancel "Error during read: $block"
            return
        } else {
            my append data $block
        }
    }

    HttpRequest instproc data_done {} {
        my instvar chan
        after cancel [my set afterId]
        fileevent $chan readable {}
        fileevent $chan writable {}
        catch {::close $chan}
        my notify successCallback [my set data]
    }

    HttpRequest instproc cancel {reason} {
        my instvar chan
        if {$reason ne "timeout"} {
            after cancel [my set afterId]
        }
        my log error $reason
        fileevent $chan readable {}
        fileevent $chan writable {}
        catch {::close $chan}
        my notify failureCallback $reason
    }


    #
    # TLS/SSL support
    #

    Class Tls
    Tls instproc send_request {} {
        my instvar chan
        ::tls::import $chan
        next
    }

    #
    # GSS/GSI support
    #

    Class Gss -parameter {
        {certProxy}
    }
    Gss instproc send_request {} {
        my instvar chan certProxy
        if {[my exists certProxy]} {
            gss::import $chan -gssimport $certProxy -server false
        } else {
            gss::import $chan -server false
        }
        next
    }

     namespace export HttpRequest
}

package provide srmlite::http 0.1
