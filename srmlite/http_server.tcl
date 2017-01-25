package require log
package require XOTcl

package require gss::socket

package require srmlite::templates

namespace eval ::srmlite::http::server {
    namespace import ::xotcl::*

# -------------------------------------------------------------------------

# HTTP/1.[01] error codes (the ones we use)

    variable errorCodes
    array set errorCodes {
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

    variable requiresBody
    array set requiresBody {
        GET 0 POST 1
    }

# -------------------------------------------------------------------------

    variable urlCache
    array set urlCache {}

# -------------------------------------------------------------------------


    Class HttpServer -parameter {
        {port 80}
        {addr}
    }


# -------------------------------------------------------------------------

    HttpServer instproc init {} {

        my array set objectMap {}
        my array set urlCache {}

        next
    }
# -------------------------------------------------------------------------

     HttpServer instproc start {} {
        my instvar port addr chan

        set myaddrOpts {}
        if {[my exists addr]} {
	    set myaddrOpts "-myaddr $addr"
        }

        set chan [socket -server [myproc accept] {*}$myaddrOpts $port]

    }

# -------------------------------------------------------------------------

    HttpServer instproc exportObject {{-object {}} {-prefix {}}} {
        my set objectMap($prefix) $object
    }

# -------------------------------------------------------------------------

# Handle file system queries.  This is a place holder for a more
# generic dispatch mechanism.

    HttpServer instproc findObject {url} {
        my instvar objectMap urlCache

        regsub {(^(http|https|httpg|srm)://[^/]+)?} $url {} url

        set object {}

        if {[my exists urlCache($url)]} {
            set object $urlCache($url)
        } else {
            set mypath [url2path $url]
            if {[my exists objectMap($mypath)]} {
                set object $objectMap($mypath)
            }
            set urlCache($url) $object
        }

        return $object
    }

# -------------------------------------------------------------------------

    HttpServer instproc accept {chan addr port} {
        HttpConnection new \
	    -childof [self] \
	    -chan $chan \
	    -addr $addr \
	    -port $port
    }

# -------------------------------------------------------------------------

    HttpServer instproc destroy {} {
        catch {::close [my set chan]}
        next
    }

# -------------------------------------------------------------------------

    Class HttpConnection -parameter {
        {chan}
        {addr}
        {port}
        {timeout 60000}
        {bufsize 32768}
        {reqleft 25}
    }

# -------------------------------------------------------------------------

    HttpConnection instproc init {} {
        my reset [my reqleft]
        my setup
        next
    }

# -------------------------------------------------------------------------

    HttpConnection instproc reset {reqleft} {
        my instvar timeout

	my reqleft $reqleft

	my set version 0
	my set url {}

        if {[my array exists mime]} {
	    my unset mime
        }

        if {[my exists postdata]} {
            my unset postdata
        }

        my set afterId [after $timeout [myproc error 408]]
    }

# -------------------------------------------------------------------------

    HttpConnection instproc setup {} {
        my instvar chan bufsize

        fconfigure $chan -blocking 0 -buffersize $bufsize -translation {auto crlf}
        fileevent $chan readable [myproc firstLine]
    }

# -------------------------------------------------------------------------

    HttpConnection instproc getLine {var} {
        my upvar $var line
        my instvar chan

        if {[catch {gets $chan line} readCount]} {
            my log error $readCount
            my log error {Broken connection fetching request}
            my done 1
            return -2
        }

        if {$readCount == -1} {
            if {[eof $chan]} {
                my log error {Broken connection fetching request}
                my done 1
                return -2
            } else {
                my log warning {No full line available, retrying...}
                return -1
            }
        }

        return $readCount
    }

# -------------------------------------------------------------------------

    HttpConnection instproc firstLine {} {
        my instvar chan method url query version

        set readCount [my getLine line]

        if {$readCount < 0} {
            return
        } elseif {$readCount == 0} {
            my log warning {Initial blank line fetching request}
            return
        }

        if {[regexp {(POST|GET) ([^?]+)\??([^ ]*) HTTP/1.([01])} $line \
                -> method url query version]} {
            my log notice Request [my reqleft] $line
            my firstLineDone
        } else {
            my error 400 $line
            return
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc firstLineDone {} {
        fileevent [my set chan] readable [myproc header]
    }

# -------------------------------------------------------------------------

    HttpConnection instproc header {} {
        my instvar mime currentKey

        set readCount [my getLine line]

        if {$readCount < 0} {
            return
        } elseif {$readCount == 0} {
            my headerDone
            return
        }

        if {[regexp {^([^:]+):\s*(.*)} $line -> key value]} {
            set key [string tolower $key]
            set currentKey $key
            if {[my exists mime($key)]} {
                append mime($key) {, } $value
            } else {
                set mime($key) $value
            }
        } elseif {[regexp {^\s+(.+)} $line -> value] && [my exists currentKey]} {
            append mime($currentKey) { } $value
        } else {
            my error 400 $line
            return
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc headerDone {} {
        my instvar chan method version mime count
        variable requiresBody

        if {[my exists mime(content-length)] &&
            [my set mime(content-length)] > 0} {
            set count $mime(content-length)
            if {$version && [my exists mime(expect)]} {
                if {[string equal $mime(expect) 100-continue]} {
                    puts $chan {100 Continue HTTP/1.1\n}
                    flush $chan
                } else {
                    my error 419 $mime(expect)
                    return
                }
            }
            my set postdata {}
            fconfigure $chan -translation {binary crlf}
            fileevent $chan readable [myproc data]
        } elseif {$requiresBody($method)} {
            my error 411 {Confusing mime headers}
            return
        } else {
            my dataDone
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc data {} {
        my instvar chan mime postdata count

        if {[eof $chan]} {
            my log error {Broken connection reading POST data}
            my done 1
            return
        } elseif {[catch {read $chan $count} block]} {
            my log error $block
            my log error {Error during read POST data}
            my done 1
            return
        } else {
            my append postdata $block
            set count [expr {$count - [string length $block]}]
            if {$count == 0} {
                my dataDone
            }
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc dataDone {} {
        my dispatch
    }

# -------------------------------------------------------------------------

# Handle file system queries.  This is a place holder for a more
# generic dispatch mechanism.

    HttpConnection instproc dispatch {} {
        my instvar chan method url
        variable requiresBody

        fileevent $chan readable {}

        set object [[my info parent] findObject $url]

        if {[Object isobject $object]} {

            if {$requiresBody($method)} {
                 set input [my set postdata]
            } else {
                 set input [decodeQuery [my set query]]
            }

            $object process [self] $input

        } else {
            my error 404
            return
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc respond {result} {
        my instvar chan version reqleft mime

        fileevent [my set chan] readable [myproc firstLine]

        puts $chan "HTTP/1.$version 200 Data follows"
        puts $chan "Date: [my date [clock seconds]]"
        puts $chan "Content-Type: text/xml; charset=utf-8"
        puts $chan "Content-Length: [string length $result]"

        ## Should also close socket if recvd connection close header
        set close [expr {$reqleft == 0}]

        if {$close} {
            puts $chan "Connection: close"
        } elseif {$version > 0 && [info exists mime(connection)]} {
            if {[string equal $mime(connection) Keep-Alive]} {
                set close 0
                puts $chan "Connection: Keep-Alive"
            }
        } else {
            set close 1
        }

        puts $chan {}
        puts $chan $result
        flush $chan

        my done $close
        return
    }

# -------------------------------------------------------------------------

# Respond with an error reply
# code:  The http error code
# args:  Additional information for error logging

    HttpConnection instproc error {code args} {
        my instvar chan url version
        variable errorFormat
	variable errorCodes

        set message [srmErrorBody $code $errorCodes($code) $url]
        append head "HTTP/1.$version $code $errorCodes($code)"  \n
        append head "Date: [my date [clock seconds]]"  \n
        append head "Connection: close"  \n
        append head "Content-Length: [string length $message]"  \n

        # Because there is an error condition, the socket may be "dead"

        catch {
            fconfigure $chan -translation crlf
            puts -nonewline $chan $head\n$message
            flush $chan
        } result

        my log error $code $errorCodes($code) $args $result
        my done 1
        return
    }

# -------------------------------------------------------------------------

    HttpConnection instproc done {close} {

        after cancel [my set afterId]

        my incr reqleft -1

        if {$close} {
            my destroy
        } else {
            my reset [my reqleft]
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc destroy {} {
        my instvar chan

        catch {
	    fileevent $chan readable {}
            ::close $chan
        }

        next
    }

# -------------------------------------------------------------------------

    HttpConnection instproc log {level args} {
        my instvar addr
        log::log $level "\[client $addr\] [join $args { }]"
    }

# -------------------------------------------------------------------------

    HttpConnection instproc date {seconds} {
        clock format $seconds -format {%a, %d %b %Y %T %Z}
    }

# -------------------------------------------------------------------------

    Class HttpServerGss -superclass HttpServer -parameter {
        {frontendService}
    }

# -------------------------------------------------------------------------

    HttpServerGss instproc accept {chan addr port} {
        HttpConnectionGss new \
	    -childof [self] \
	    -chan $chan \
	    -addr $addr \
	    -port $port \
	    -frontendService [my frontendService]
    }

# -------------------------------------------------------------------------

    Class HttpConnectionGss -superclass HttpConnection -parameter {
        {frontendService}
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc setup {} {
        my instvar chan bufsize
        if {[catch {gss::import $chan -server true} result]} {
            my log error {Error during gssimport:} $result
            my done 1
            return
        }
        next
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc dataDone {} {
        my authorization
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc authorization {} {
        my instvar chan

	fileevent $chan readable {}

        my log notice {Distinguished name} [fconfigure $chan -gssname]
        if {[catch {fconfigure $chan -gsscontext} result]} {
            my log error {Error during gsscontext:} $result
            my done 1
            return
        }
        [my frontendService] process [list authorization [self] $result]
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc authorizationSuccess {userName} {
        my set userName $userName
        my dispatch
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc authorizationFailure {reason} {
	my log error {Authorization failed:} $reason
        my error 403 {Acess is not allowed}
    }

# -------------------------------------------------------------------------
# Convert a url into a pathname. (UNIX version only)
# This is probably not right, and belongs somewhere else.
# - Remove leading http://... if any
# - Collapse all /./ and /../ constructs
# - expand %xx sequences -> disallow "/"'s  and "."'s due to expansions

    proc url2path {url} {
        regsub -all {//+} $url / url                ;# collapse multiple /'s
        while {[regsub -all {/\./} $url / url]} {}  ;# collapse /./
        while {[regsub -all {/\.\.(/|$)} $url /\x81\\1 url]} {} ;# mark /../
        while {[regsub {/\[^/\x81]+/\x81/} $url / url]} {} ;# collapse /../
        if {![regexp {\x81|%2\[eEfF]} $url]} {      ;# invalid /../, / or . ?
            return [decodeUrl $url]
        } else {
            return {}
        }
    }

# -------------------------------------------------------------------------
# Decode url-encoded strings.

    proc decodeUrl {data} {
        # jcw wiki webserver
        # @c Decode url-encoded strings

        regsub -all {\+} $data { } data
        regsub -all {([][$\\])} $data {\\\1} data
        regsub -all {%([0-9a-fA-F][0-9a-fA-F])} $data {[format %c 0x\1]} data

        return [subst -novariables -nobackslashes $data]
    }

# -------------------------------------------------------------------------

    proc decodeQuery {query} {
        # jcw wiki webserver
        # @c Decode url-encoded query into key/value pairs

        set result [list]

        regsub -all {[&=]} $query { }    query
        regsub -all {  }   $query { {} } query; # Othewise we lose empty values

        foreach {key val} $query {
            lappend result [decodeUrl $key] [decodeUrl $val]
        }

        return $result
    }

# -------------------------------------------------------------------------

     namespace export HttpServer HttpServerGss
}

package provide srmlite::http::server 0.2
