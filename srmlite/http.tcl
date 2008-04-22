# XOTcl implementation for asynchronous HTTP and HTTPs requests
# author Gustaf Neumann, Stefan Sobernig, Pavel Demin
# creation-date 2008-04-21
# cvs-id $Id: http.tcl,v 1.1 2008-04-22 07:54:44 demin Exp $

namespace eval ::srmlite::http {
  #
  # Defined classes
  #  1) HttpRequest
  #  2) Tls (mixin class)
  #  3) Gss (mixin class)
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
  #  Object ::listener \
  #     -proc deliver {payload obj} {
  #       my log "Asynchronous request suceeded!"
  #     } -proc done {reason obj} {
  #       my log "Asynchronous request failed: $reason"
  #     }
  #
  # (b)  Create the actual asynchronous request object.
  # Make sure that you specify the previously created listener/callback
  # object as "request_manager" to the request object.
  #
  #  HttpRequest new \
  #     -url "https://oacs-dotlrn-conf2007.wu-wien.ac.at/conf2007/" \
  #     -request_manager ::listener
  #

  Class create HttpRequest \
      -parameter {
	{host}
	{protocol http}
	{port}
	{path /}
        {url}
	{post_data ""}
	{accept */*}
	{content_type text/plain}
	{request_manager}
	{request_header_fields {}}
        {user_agent xohttp/0.1}
        {timeout 60000}
      }

  HttpRequest instproc set_default_port {protocol} {
    switch $protocol {
      http  {my set port 80}
      https {my set port 443}
      srm -
      httpg {my set port 8443}
    }
  }

  HttpRequest instproc parse_url {} {
    my instvar protocol url host port path
    if {[regexp {^(http|https|srm|httpg)://([^/]+)(/.*)?$} $url _ protocol host path]} {
      # Be friendly and allow strictly speaking invalid urls
      # like "http://www.openacs.org"  (no trailing slash)
      if {$path eq ""} {set path /}
      my set_default_port $protocol
      regexp {^([^:]+):(.*)$} $host _ host port
    } else {
      error "unsupported or invalid url '$url'"
    }
  }

  HttpRequest instproc open_connection {} {
    my instvar host port S
    set S [socket -async $host $port]
    fileevent $S writable [list [self] open_connection_done]
  }

  HttpRequest instproc open_connection_done {} {
    my instvar host port S
    fileevent $S writable {}

    if {[catch {my send_request} err]} {
      my cancel "error send $host $port: $err"
      return
    }
  }

  HttpRequest instproc set_encoding {
    {-text_translation {auto binary}}
    content_type
  } {
    #
    # for text, use translation with optional encodings, else set translation binary
    #
    if {[string match "text/*" $content_type]} {
      if {[regexp {charset=([^ ]+)$} $content_type _ encoding]} {
	fconfigure [my set S] -translation $text_translation -encoding [string tolower $encoding]
      } else {
	fconfigure [my set S] -translation $text_translation
      }
    } else {
      fconfigure [my set S] -translation binary
    }
  }

  HttpRequest instproc init {} {
    my instvar S post_data host port protocol
    my set to_identifier [after [my set timeout] [self] cancel timeout]
    my set meta [list]
    my set data ""
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

    if {[catch {my open_connection} err]} {
      my cancel "error during open connection via $protocol to $host $port: $err"
      return
    }
  }

  HttpRequest instproc send_request {} {
    my instvar S post_data host port protocol

    fconfigure $S -blocking false

    set method [expr {$post_data eq "" ? "GET" : "POST"}]
    puts $S "$method [my path] HTTP/1.0"
    puts $S "Accept: [my accept]"
    puts $S "Host: $host"
    puts $S "User-Agent: [my user_agent]"
    foreach {tag value} [my request_header_fields] {
	#regsub -all \[\n\r\] $value {} value
	#set tag [string trim $tag]
      puts $S "$tag: $value"
    }
    my $method
  }

  HttpRequest instproc GET {} {
    my instvar S
    puts $S ""
    my query_done
  }

  HttpRequest instproc POST {} {
    my instvar S post_data
    puts $S "Content-Type: [my content_type]"
    puts $S "Content-Length: [string length $post_data]"
    puts $S ""
    my set_encoding [my content_type]
    puts -nonewline $S $post_data
    my query_done
  }

  HttpRequest instproc query_done {} {
    my instvar S
    flush $S
    fileevent $S readable [list [self] received_first_line]
  }

  HttpRequest instproc notify {method arg} {
    if {[my exists request_manager]} {
      [my request_manager] $method $arg [self]
    }
  }

  HttpRequest instproc cancel {reason} {
    if {$reason ne "timeout"} {
      after cancel [my set to_identifier]
    }
    my log "--- $reason"
    catch {close [my set S]}
    my notify done $reason
  }

  HttpRequest instproc finish {} {
    after cancel [my set to_identifier]
    catch {close [my set S]}
    my log "--- [my host] [my port] [my path] has finished"
    my notify deliver [my set data]
  }

  HttpRequest instproc getLine {var} {
    my upvar $var response
    my instvar S
    set n [gets $S response]
    if {[eof $S]} {
      my log "--premature eof"
      return -2
    }
    if {$n == -1} {my log "--input pending, no full line"; return -1}
    #my log "got $response"
    return $n
  }

  HttpRequest instproc received_first_line {} {
    my instvar S status_code
    fconfigure $S -translation crlf
    set n [my getLine response]
    puts $response
    switch -exact -- $n {
      -2 {my cancel premature-eof; return}
      -1 {return}
    }
    if {[regexp {^HTTP/([0-9.]+) +([0-9]+) *} $response _ \
	     responseHttpVersion status_code]} {
      my received_first_line_done
    } else {
      my log "--unexpected response '$response'"
      my cancel unexpected-response
    }
  }

  HttpRequest instproc received_first_line_done {} {
    fileevent [my set S] readable [list [self] header]
  }

  HttpRequest instproc header {} {
    while {1} {
      set n [my getLine response]
      puts $response
      switch -exact -- $n {
	-2 {my cancel premature-eof; return}
	-1 {continue}
	0 {break}
	default {
	  #my log "--header $response"
	  if {[regexp -nocase {^content-length:(.+)$} $response _ length]} {
	    my set content_length [string trim $length]
	  } elseif {[regexp -nocase {^content-type:(.+)$} $response _ type]} {
	    my set content_type [string trim $type]
	  }
	  if {[regexp -nocase {^([^:]+): *(.+)$} $response _ key value]} {
	    my lappend meta [string tolower $key] $value
	  }
	}
      }
    }
    my received_header_done
  }

  HttpRequest instproc received_header_done {} {
    # we have received the header, including potentially the content_type of the returned data
    my set_encoding [my content_type]
    fileevent [my set S] readable [list [self] received_data]
  }

  HttpRequest instproc received_data {} {
    my instvar S
    if {[eof $S]} {
      my finish
    } else {
      set block [read $S]
      my append data $block
    }
  }

  #
  # TLS/SSL support
  #

  Class Tls
  Tls instproc send_request {} {
    my instvar S
    ::tls::import $S
    next
  }

  #
  # GSS/GSI support
  #

  Class Gss -parameter {
    {cert_proxy}
  }
  Gss instproc send_request {} {
    my instvar S cert_proxy
    if {[my exists cert_proxy]} {
      gss::import $S -gssimport $cert_proxy -server false
    } else {
      gss::import $S -server false
    }
    next
  }

   namespace export HttpRequest AsyncHttpRequest HttpRequestTrace
}

package provide srmlite::http 0.1
