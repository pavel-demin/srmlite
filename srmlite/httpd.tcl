
# -------------------------------------------------------------------------

# HTTP/1.[01] error codes (the ones we use)

array set HttpdErrors {
    204 {No Content}
    400 {Bad Request}
    403 {Forbidden}
    404 {Not Found}
    408 {Request Timeout}
    411 {Length Required}
    419 {Expectation Failed}
    503 {Service Unavailable}
    504 {Service Temporarily Unavailable}
}

# -------------------------------------------------------------------------

# Httpd is a global array containing the global server state
#  root:        the root of the document directory
#  port:        The port this server is serving
#  listen:      the main listening socket id
#  accepts:     a count of accepted connections so far
#  maxtime:     The max time (msec) allowed to complete an http request
#  maxused:     The max # of requests for a socket

array set Httpd {
    requestId   -2147483648
    bufsize     32768
    maxtime     60000
    maxused     25
    encoding    "utf-8"
}

# -------------------------------------------------------------------------

# convert the file suffix into a mime type
# add your own types as needed

array set HttpdMimeTypes {
    {}    "text/plain"
    .txt  "text/plain"
    .css  "text/css"
    .js   "text/javascript"
    .htm  "text/html; charset=$Httpd(encoding)"
    .html "text/html; charset=$Httpd(encoding)"
    .gif  "image/gif"
    .jpg  "image/jpeg"
    .ico  "image/ico"
}

# -------------------------------------------------------------------------

# Start the server by listening for connections on the desired port.

proc HttpdServer {root {port 80} {default index.html}} {
    global Httpd

    catch {close Httpd(port)}   ;# it might already be running
    array set Httpd [list root $root default $default port $port]
    array set Httpd [list accepts 0 requests 0 errors 0]
    set Httpd(listen) [socket -server HttpdAccept $port]
    return $Httpd(port)
}

# -------------------------------------------------------------------------

# Accept a new connection from the server and set up a handler
# to read the request from the client.

proc HttpdAccept {sock ipaddr {port {}}} {
    global Httpd
    upvar #0 Httpd$sock data

    incr Httpd(accepts)
    HttpdReset $sock $Httpd(maxused)
    HttpdLog $sock notice {Connected to port} $port
}

# -------------------------------------------------------------------------

proc HttpdNewRequestId {} {

    global Httpd

    return [incr Httpd(requestId)]
}

# -------------------------------------------------------------------------

# Initialize or reset the socket state

proc HttpdReset {sock left} {
    global Httpd
    upvar #0 Httpd$sock data

    array set data [list state start linemode 1 version 0 left $left counter 0]
    set data(address) [lindex [fconfigure $sock -peername] 0]
    set data(cancel) [after $Httpd(maxtime) [list HttpdTimeout $sock]]
    set data(requestId) [HttpdNewRequestId]

    gss::import $sock -server true

    fconfigure $sock -blocking 0 -buffersize $Httpd(bufsize) -translation {auto crlf}

    fileevent $sock readable [list HttpdRead $sock]
}

# -------------------------------------------------------------------------

# Read data from a client request
# 1) read the request line
# 2) read the mime headers
# 3) read the additional data (if post && content-length not satisfied)

proc HttpdRead {sock} {
    global Httpd
    upvar #0 Httpd$sock data
    
    if {$data(counter) == 0 && ![eof $sock]} {
        HttpdLog $sock notice {Distinguished name} [fconfigure $sock -gssname]
        incr data(counter)
    }

    # Use line mode to read the request and the mime headers

    if {$data(linemode)} {
        set readCount [gets $sock line]
        set state [string compare $readCount 0],$data(state)
        switch -glob -- $state {
            1,start {
                if {[regexp {(HEAD|POST|GET) ([^?]+)\??([^ ]*) HTTP/1.([01])} $line \
                        -> data(proto) data(url) data(query) data(version)]} {
                    set data(state) mime
                    incr Httpd(requests)
                    HttpdLog $sock notice Request $data(left) $line
                } else {
                    HttpdError $sock 400 $line
                }
            }
            0,start {
                HttpdLog $sock warning {Initial blank line fetching request}
            }
            1,mime {
                if {[regexp {([^:]+):[  ]*(.*)} $line -> key value]} {
                    set key [string tolower $key]
                    set data(key) $key
                    if {[info exists data(mime,$key)]} {
                        append data(mime,$key) ", $value"
                    } else {
                        set data(mime,$key) $value
                    }
                } elseif {[regexp {^[   ]+(.+)} $line -> value] && \
                        [info exists data(key)]} {
                    append data(mime,$data($key)) " " $value
                } else {
                    HttpdError $sock 400 $line
                }
            }
            0,mime {
                if {$data(proto) == "POST" && \
                        [info exists data(mime,content-length)]} {
                    set data(linemode) 0
                    set data(count) $data(mime,content-length)
                    if {$data(version) && [info exists data(mime,expect]} {
                        if {$data(mime,expect) == "100-continue"} {
                            puts $sock "100 Continue HTTP/1.1\n"
                            flush $sock
                        } else {
                            HttpdError $sock 419 $data(mime,expect)
                        }
                    }
                    fconfigure $sock -translation {binary crlf}
                } elseif {$data(proto) != "POST"}  {
                    HttpdRespond $sock
                } else {
                    HttpdError $sock 411 {Confusing mime headers}
                }
            }
            -1,* {
                if {[eof $sock]} {
                    HttpdLog $sock error {Broken connection fetching request}
                    HttpdSockDone $sock 1
                } else {
                    HttpdLog $sock warning {Partial read, retrying...}
                }
            }
            default {
                HttpdError $sock 404 "Invalid http state: $state,[eof $sock]"
            }
        }

    # Use counted mode to get the post data

    } elseif {![eof $sock]} {
        append data(postdata) [read $sock $data(count)]
        set data(count) [expr {$data(mime,content-length) - \
                [string length $data(postdata)]}]
        if {$data(count) == 0} {
            HttpdRespond $sock
        }
    } else {
        HttpdLog $sock error {Broken connection reading POST data}
        HttpdSockDone $sock 1
    }
}

# -------------------------------------------------------------------------

# Done with the socket, either close it, or set up for next fetch
#  sock:  The socket I'm done with
#  close: If true, close the socket, otherwise set up for reuse

proc HttpdSockDone {sock close} {
    global Httpd
    upvar #0 Httpd$sock data

    after cancel $data(cancel)

    set left [incr data(left) -1]
    unset data
    if {$close} {
        close $sock
    } else {
        HttpdReset $sock $left
    }
    return ""
}

# -------------------------------------------------------------------------

# A timeout happened

proc HttpdTimeout {sock} {
    global Httpd
    upvar #0 Httpd$sock data
    HttpdError $sock 408
}

# -------------------------------------------------------------------------

# Handle file system queries.  This is a place holder for a more
# generic dispatch mechanism.

proc HttpdRespond {sock} {
    global Httpd HttpdUrlCache
    upvar #0 Httpd$sock data

    regsub {(^(http|https|httpg)://[^/]+)?} $data(url) {} url
    if {[info exists HttpdUrlCache($url)]} {
        set mypath $HttpdUrlCache($url)
    } else {
        set procpath [HttpdUrl2File $url]

        if {[info proc $procpath] eq "$procpath" &&
            [string length $procpath] != 0} {
            set HttpdUrlCache($url) $procpath
            set mypath $procpath
        } else {
            set HttpdUrlCache($url) {}
            set mypath {}
        }
    }

    if {[string length $mypath] == 0} {
        HttpdError $sock 400
    } elseif {[info proc $mypath] eq "$mypath"} {
        # Service URL-procedure
        switch -- $data(proto) {
            GET { set input [HttpdQueryMap $data(query)]}
            POST { set input $data(postdata) }
        }

        set requestId $data(requestId)

        fileevent $sock readable {}

        if {[catch {eval [list $mypath $sock $requestId $input]} result]} {
            fileevent $sock readable [list HttpdRead $sock]
            HttpdError $sock 503
            HttpdLog $sock error $mypath: $result
        }
    } else {
        HttpdError $sock 404 $mypath
    }
}

# -------------------------------------------------------------------------

proc HttpdResult {sock result} {

    global Httpd HttpdUrlCache
    upvar #0 Httpd$sock data

    fileevent $sock readable [list HttpdRead $sock]

    puts $sock "HTTP/1.$data(version) 200 Data follows"
    puts $sock "Date: [HttpdDate [clock seconds]]"
    puts $sock "Content-Type: text/xml; charset=utf-8"
    puts $sock "Content-Length: [string length $result]"

    ## Should also close socket if recvd connection close header
    set close [expr {$data(left) == 0}]

    if {$close} {
        puts $sock "Connection close:"
    } elseif {$data(version) == 1 && [info exists data(mime,connection)]} {
        if {$data(mime,connection) == "Keep-Alive"} {
            set close 0
            puts $sock "Connection: Keep-Alive"
        }
    } else {
        set close 1
    }

    puts $sock ""
    puts $sock $result
    flush $sock
    HttpdSockDone $sock $close
}

# -------------------------------------------------------------------------

# Generic error response.

set HttpdErrorFormat {
    <title>Error: %1$s</title>
    Got the error: <b>%2$s</b><br>
    while trying to obtain <b>%3$s</b>
}

# -------------------------------------------------------------------------

# Respond with an error reply
# sock:  The socket handle to the client
# code:  The httpd error code
# args:  Additional information for error logging

proc HttpdError {sock code args} {
    upvar #0 Httpd$sock data
    global Httpd HttpdErrors HttpdErrorFormat

    append data(url) ""
    incr Httpd(errors)
    set message [format $HttpdErrorFormat $code $HttpdErrors($code) $data(url)]
    append head "HTTP/1.$data(version) $code $HttpdErrors($code)"  \n
    append head "Date: [HttpdDate [clock seconds]]"  \n
    append head "Connection: close"  \n
    append head "Content-Length: [string length $message]"  \n

    # Because there is an error condition, the socket may be "dead"

    catch {
        fconfigure $sock  -translation crlf
        puts -nonewline $sock $head\n$message
        flush $sock
    } reason
    HttpdLog $sock error $code $HttpdErrors($code) $args $reason
    KillSrmRequest $data(requestId)
    HttpdSockDone $sock 1
}

# -------------------------------------------------------------------------

# Generate a date string in HTTP format.

proc HttpdDate {seconds} {
    return [clock format $seconds -format {%a, %d %b %Y %T %Z}]
}

# -------------------------------------------------------------------------

# Log an Httpd transaction.
# This should be replaced as needed.

proc HttpdLog {sock level args} {
    upvar #0 Httpd$sock data
    log::log $level "\[client $data(address)\] [join $args { }]"
}

# -------------------------------------------------------------------------

# Convert a url into a pathname. (UNIX version only)
# This is probably not right, and belongs somewhere else.
# - Remove leading http://... if any
# - Collapse all /./ and /../ constructs
# - expand %xx sequences -> disallow "/"'s  and "."'s due to expansions

proc HttpdUrl2File {url} {
    regsub -all {//+} $url / url                ;# collapse multiple /'s
    while {[regsub -all {/\./} $url / url]} {}  ;# collapse /./
    while {[regsub -all {/\.\.(/|$)} $url /\x81\\1 url]} {} ;# mark /../
    while {[regsub {/\[^/\x81]+/\x81/} $url / url]} {} ;# collapse /../
    if {![regexp {\x81|%2\[eEfF]} $url]} {      ;# invalid /../, / or . ?
        return [HttpdCgiMap $url]
    } else {
        return {}
    }
}

# -------------------------------------------------------------------------

# Decode url-encoded strings.

proc HttpdCgiMap { data } {
  # jcw wiki webserver
  # @c Decode url-encoded strings

  regsub -all {\+} $data { } data
  regsub -all {([][$\\])} $data {\\\1} data
  regsub -all {%([0-9a-fA-F][0-9a-fA-F])} $data {[format %c 0x\1]} data

  return [subst $data]
}

# -------------------------------------------------------------------------

proc HttpdQueryMap { query } {
  # jcw wiki webserver
  # @c Decode url-encoded query into key/value pairs

  set res [list]

  regsub -all {[&=]} $query { }    query
  regsub -all {  }   $query { {} } query; # Othewise we lose empty values

  foreach {key val} $query {
      lappend res [CgiMap $key] [CgiMap $val]
  }
  return $res
}

# -------------------------------------------------------------------------

package provide srmlite::httpd 0.1
