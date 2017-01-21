package require log
package require TclOO

package require gss::socket

package require srmlite::templates

proc ::oo::Helpers::mymethod {method args} {
  list [uplevel 1 {namespace which my}] $method {*}$args
}

namespace eval ::srmlite::http::server {

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


    oo::class create HttpServer


# -------------------------------------------------------------------------

    oo::define HttpServer constructor args {
        my variable port addr objectMap urlCache

        set port 80

        foreach {param value} $args {
            if {$param eq "-port"} {
                set port $value
            } elseif {$param eq "-addr"} {
                set addr $value
            } else {
                error "unsupported parameter $param"
            }
        }

        array set objectMap {}
        array set urlCache {}
    }

# -------------------------------------------------------------------------

     oo::define HttpServer method start {} {
        my variable port addr chan

        set myaddrOpts {}
        if {[info exists addr]} {
            set myaddrOpts "-myaddr $addr"
        }

        set chan [eval [list socket -server [mymethod accept]] $myaddrOpts $port]
    }

# -------------------------------------------------------------------------

    oo::define HttpServer method exportObject {prefix object} {
        my variable objectMap

        set objectMap($prefix) $object
    }

# -------------------------------------------------------------------------

    oo::define HttpServer method findObject {url} {
        my variable objectMap urlCache

        regsub {(^(http|https|httpg|srm)://[^/]+)?} $url {} url

        set object {}

        if {[info exists urlCache($url)]} {
            set object $urlCache($url)
        } else {
            set mypath [url2path $url]
            if {[info exists objectMap($mypath)]} {
                set object $objectMap($mypath)
            }
            set urlCache($url) $object
        }

        return $object
    }

# -------------------------------------------------------------------------

    oo::define HttpServer method accept {chan addr port} {
        HttpConnection new \
            -parent [self] \
            -chan $chan \
            -addr $addr \
            -port $port
    }

# -------------------------------------------------------------------------

    oo::define HttpServer method destroy {} {
        my variable chan

        catch {::close $chan}
    }

# -------------------------------------------------------------------------

    oo::class create HttpConnection

# -------------------------------------------------------------------------

    oo::define HttpConnection constructor args {
        my variable parent chan addr port timeout bufsize reqleft

        set timeout 60000
        set bufsize 32768
        set reqleft 25

        foreach {param value} $args {
            if {$param eq "-parent"} {
                set parent $value
            } elseif {$param eq "-chan"} {
                set chan $value
            } elseif {$param eq "-addr"} {
                set addr $value
            } elseif {$param eq "-port"} {
                set port $value
            } elseif {$param eq "-timeout"} {
                set timeout $value
            } elseif {$param eq "-bufsize"} {
                set bufsize $value
            } elseif {$param eq "-reqleft"} {
                set reqleft $value
            } else {
                error "unsupported parameter $param"
            }
        }

        my reset
        my setup
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method reset {} {
        my variable timeout version url mime postdata afterId

        set version 0
        set url {}

        if {[array exists mime]} {
            array unset mime
        }

        if {[info exists postdata]} {
            unset postdata
        }

        set afterId [after $timeout [mymethod error 408]]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method setup {} {
        my variable chan bufsize

        fconfigure $chan -blocking 0 -buffersize $bufsize -translation {auto crlf}
        fileevent $chan readable [mymethod firstLine]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method getLine {var} {
        my variable chan

        upvar $var line

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

    oo::define HttpConnection method firstLine {} {
        my variable chan reqleft method url query version

        set readCount [my getLine line]

        if {$readCount < 0} {
            return
        } elseif {$readCount == 0} {
            my log warning {Initial blank line fetching request}
            return
        }

        if {[regexp {(POST|GET) ([^?]+)\??([^ ]*) HTTP/1.([01])} $line \
                -> method url query version]} {
            my log notice Request $reqleft $line
            my firstLineDone
        } else {
            my error 400 $line
            return
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method firstLineDone {} {
        my variable chan

        fileevent $chan readable [mymethod header]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method header {} {
        my variable mime currentKey

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
            if {[info exists mime($key)]} {
                append mime($key) {, } $value
            } else {
                set mime($key) $value
            }
        } elseif {[regexp {^\s+(.+)} $line -> value] && [info exists currentKey]} {
            append mime($currentKey) { } $value
        } else {
            my error 400 $line
            return
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method headerDone {} {
        my variable chan method version mime postdata count
        variable requiresBody

        if {[info exists mime(content-length)] &&
            $mime(content-length) > 0} {
            set count $mime(content-length)
            if {$version && [info exists mime(expect)]} {
                if {[string equal $mime(expect) 100-continue]} {
                    puts $chan {100 Continue HTTP/1.1\n}
                    flush $chan
                } else {
                    my error 419 $mime(expect)
                    return
                }
            }
            set postdata {}
            fconfigure $chan -translation {binary crlf}
            fileevent $chan readable [mymethod data]
        } elseif {$requiresBody($method)} {
            my error 411 {Confusing mime headers}
            return
        } else {
            my dataDone
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method data {} {
        my variable chan mime postdata count

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

    oo::define HttpConnection method dataDone {} {
        my dispatch
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method dispatch {} {
        my variable parent chan method url postdata query
        variable requiresBody

        fileevent $chan readable {}

        set object [$parent findObject $url]

        if {[info object isa object $object]} {

            if {$requiresBody($method)} {
                 set input $postdata
            } else {
                 set input [decodeQuery $query]
            }

            $object process [self] $input

        } else {
            my error 404
            return
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method respond {result} {
        my variable chan reqleft version mime

        fileevent $chan readable [mymethod firstLine]

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
# code: The http error code
# args: Additional information for error logging

    oo::define HttpConnection method error {code args} {
        my variable chan url version
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

    oo::define HttpConnection method done {close} {
        my variable reqleft afterId

        after cancel $afterId

        incr reqleft -1

        if {$close} {
            my destroy
        } else {
            my reset
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method destroy {} {
        my variable chan

        catch {
            fileevent $chan readable {}
            ::close $chan
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method log {level args} {
        my variable addr
        log::log $level "\[client $addr\] [join $args { }]"
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method date {seconds} {
        clock format $seconds -format {%a, %d %b %Y %T %Z}
    }

# -------------------------------------------------------------------------

    oo::class create HttpServerGss
    oo::define HttpServerGss superclass HttpServer

# -------------------------------------------------------------------------

    oo::define HttpServerGss constructor args {
        my variable frontendService

        set argsNext [list]

        foreach {param value} $args {
            if {$param eq "-frontendService"} {
                set frontendService $value
            } else {
                lappend argsNext $param $value
            }
        }

        next {*}$argsNext
    }

# -------------------------------------------------------------------------

    oo::define HttpServerGss method accept {chan addr port} {
        my variable frontendService

        HttpConnectionGss new \
            -parent [self] \
            -chan $chan \
            -addr $addr \
            -port $port \
            -frontendService $frontendService
    }

# -------------------------------------------------------------------------

    oo::class create HttpConnectionGss
    oo::define HttpConnectionGss superclass HttpConnection

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss constructor args {
        my variable frontendService

        set argsNext [list]

        foreach {param value} $args {
            if {$param eq "-frontendService"} {
                set frontendService $value
            } else {
                lappend argsNext $param $value
            }
        }

        next {*}$argsNext
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method setup {} {
        my variable chan bufsize
        if {[catch {gss::import $chan -server true} result]} {
            my log error {Error during gssimport:} $result
            my done 1
            return
        }
        next
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method dataDone {} {
        my authorization
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method authorization {} {
        my variable frontendService chan

        fileevent $chan readable {}

        my log notice {Distinguished name} [fconfigure $chan -gssname]
        if {[catch {fconfigure $chan -gsscontext} result]} {
            my log error {Error during gsscontext:} $result
            my done 1
            return
        }
        $frontendService process [list authorization [self] $result]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method authorizationSuccess {name} {
        my variable userName

        set userName $name
        my dispatch
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method authorizationFailure {reason} {
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
