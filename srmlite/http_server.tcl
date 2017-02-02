package require log
package require TclOO

package require gssctx

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


    oo::class create HttpServer
    oo::define HttpServer variable channel address port objectMap urlCache


# -------------------------------------------------------------------------

    oo::define HttpServer constructor {args} {
        namespace path [list {*}[namespace path] ::srmlite::http::server]

        set port 80

        foreach {param value} $args {
            if {$param eq {-port}} {
                set port $value
            } elseif {$param eq {-address}} {
                set address $value
            } else {
                error "unsupported parameter $param"
            }
        }

        array set objectMap {}
        array set urlCache {}
    }

# -------------------------------------------------------------------------

     oo::define HttpServer method start {} {
        set myaddrOpts {}
        if {[info exists address]} {
            set myaddrOpts "-myaddr $address"
        }

        set channel [socket -server [mymethod accept] {*}$myaddrOpts $port]
    }

# -------------------------------------------------------------------------

    oo::define HttpServer method exportObject {prefix object} {
        set objectMap($prefix) $object
    }

# -------------------------------------------------------------------------

    oo::define HttpServer method findObject {url} {
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

    oo::define HttpServer method accept {channel address port} {
        HttpConnection new \
            -parent [self] \
            -channel $channel \
            -address $address \
            -port $port
    }

# -------------------------------------------------------------------------

    oo::define HttpServer method destroy {} {
        catch {chan close $channel}
    }

# -------------------------------------------------------------------------

    oo::class create HttpConnection
    oo::define HttpConnection variable parent channel address port afterId count currentKey method mime postdata query reqleft timeout url version

# -------------------------------------------------------------------------

    oo::define HttpConnection constructor {args} {
        namespace path [list {*}[namespace path] ::srmlite::http::server]

        set timeout 3600000
        set reqleft 25

        foreach {param value} $args {
            if {$param eq {-parent}} {
                set parent $value
            } elseif {$param eq {-channel}} {
                set channel $value
            } elseif {$param eq {-address}} {
                set address $value
            } elseif {$param eq {-port}} {
                set port $value
            } elseif {$param eq {-timeout}} {
                set timeout $value
            } elseif {$param eq {-reqleft}} {
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
        chan configure $channel -buffersize 16384
        chan configure $channel -blocking 0 -translation {auto crlf}
        chan event $channel readable [mymethod firstLine]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method getLine {var} {
        upvar $var line

        if {[catch {chan gets $channel line} readCount]} {
            my log error $readCount
            my log error {Broken connection fetching request}
            my done 1
            return -2
        }

        if {$readCount == -1} {
            if {[chan eof $channel]} {
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
        chan event $channel readable [mymethod header]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method header {} {
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
        namespace upvar ::srmlite::http::server requiresBody requiresBody

        if {[info exists mime(content-length)] &&
            $mime(content-length) > 0} {
            set count $mime(content-length)
            if {$version && [info exists mime(expect)]} {
                if {$mime(expect) eq {100-continue}} {
                    chan puts $channel {100 Continue HTTP/1.1\n}
                    chan flush $channel
                } else {
                    my error 419 $mime(expect)
                    return
                }
            }
            set postdata {}
            chan configure $channel -translation {binary crlf}
            chan event $channel readable [mymethod data]
        } elseif {$requiresBody($method)} {
            my error 411 {Confusing mime headers}
            return
        } else {
            my dataDone
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method data {} {
        if {[catch {chan read $channel $count} block]} {
            my log error $block
            my log error {Error during read POST data}
            my done 1
            return
        }

        if {[chan eof $channel]} {
            my log error {Broken connection reading POST data}
            my done 1
            return
        }

        append postdata $block
        set count [expr {$count - [string length $block]}]
        if {$count == 0} {
            my dataDone
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method dataDone {} {
        my dispatch
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method dispatch {} {
        namespace upvar ::srmlite::http::server requiresBody requiresBody

        chan event $channel readable {}

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
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method respond {result} {
        chan configure $channel -translation {auto crlf}

        chan puts $channel "HTTP/1.$version 200 Data follows"
        chan puts $channel "Date: [my date [clock seconds]]"
        chan puts $channel "Content-Type: text/xml; charset=utf-8"
        chan puts $channel "Content-Length: [string length $result]"

        # Should also close socket if received connection close header
        set close [expr {$reqleft == 0}]

        if {$close} {
            chan puts $channel "Connection: close"
        } elseif {$version > 0 && [info exists mime(connection)]} {
            if {$mime(connection) eq {Keep-Alive}} {
                set close 0
                chan puts $channel "Connection: Keep-Alive"
            }
        } else {
            set close 1
        }

        chan puts $channel {}
        chan configure $channel -translation {auto binary}
        chan puts -nonewline $channel $result
        chan flush $channel

        my done $close
    }

# -------------------------------------------------------------------------

# Respond with an error reply
# code: The http error code
# args: Additional information for error logging

    oo::define HttpConnection method error {code args} {
        namespace upvar ::srmlite::http::server errorCodes errorCodes

        set message [srmErrorBody $code $errorCodes($code) $url]
        append head "HTTP/1.$version $code $errorCodes($code)" \n
        append head "Date: [my date [clock seconds]]" \n
        append head "Connection: close" \n
        append head "Content-Length: [string length $message]" \n

        # Because there is an error condition, the socket may be "dead"

        catch {
            chan configure $channel -translation {auto crlf}
            chan puts $channel $head
            chan configure $channel -translation {auto binary}
            chan puts -nonewline $channel $message
            chan flush $channel
        } result

        my log error $code $errorCodes($code) $args $result
        my done 1
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method done {close} {
        after cancel $afterId

        incr reqleft -1

        if {$close} {
            my destroy
        } else {
            my reset
            chan configure $channel -translation {auto crlf}
            chan event $channel readable [mymethod firstLine]
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method destroy {} {
        catch {
            chan event $channel readable {}
            chan close $channel
        }
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method log {level args} {
        log::log $level "\[client $address\] [join $args { }]"
    }

# -------------------------------------------------------------------------

    oo::define HttpConnection method date {seconds} {
        clock format $seconds -format {%a, %d %b %Y %T %Z}
    }

# -------------------------------------------------------------------------

    oo::class create HttpServerGss
    oo::define HttpServerGss superclass HttpServer
    oo::define HttpServerGss variable frontendService

# -------------------------------------------------------------------------

    oo::define HttpServerGss constructor {args} {
        namespace path [list {*}[namespace path] ::srmlite::http::server]

        set argsNext [list]

        foreach {param value} $args {
            if {$param eq {-frontendService}} {
                set frontendService $value
            } else {
                lappend argsNext $param $value
            }
        }

        next {*}$argsNext
    }

# -------------------------------------------------------------------------

    oo::define HttpServerGss method accept {channel address port} {
        HttpConnectionGss new \
            -parent [self] \
            -channel $channel \
            -address $address \
            -port $port \
            -frontendService $frontendService
    }

# -------------------------------------------------------------------------

    oo::class create ChannelGss
    oo::define ChannelGss variable channel connection context ready buffer

# -------------------------------------------------------------------------

    oo::define ChannelGss constructor {args} {
        foreach {param value} $args {
            if {$param eq {-channel}} {
                set channel $value
            } elseif {$param eq {-connection}} {
                set connection $value
            } else {
                error "unsupported parameter $param"
            }
        }

        set ready 0
        if {[info exists channel]} {
            set context [gssctx $channel]
            chan configure $channel -buffersize 16389
            chan configure $channel -blocking 0 -translation {binary binary}
        }
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss destructor {
        $context destroy
        chan close $channel
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss method initialize {id mode} {
        return {initialize finalize watch read write}
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss method finalize {id} {
        my destroy
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss method callback {id} {
        set code [catch {$context read} result]
        switch -- $code {
            0 {
                set ready 1
                set buffer $result
                chan event $channel readable {}
                chan postevent $id {read}
            }
            1 {
                set buffer {}
                chan event $channel readable {}
                chan postevent $id {read}
                $connection log error $result
            }
        }
    }

# ---------------------------------------------------------------------

    oo::define ChannelGss method watch {id events} {
        if {"read" in $events} {
            if {$ready} {
                chan postevent $id {read}
            } else {
                chan event $channel readable [mymethod callback $id]
            }
        } else {
            chan event $channel readable {}
        }
    }

# ---------------------------------------------------------------------

    oo::define ChannelGss method read {id count} {
        chan event $channel readable [mymethod callback $id]
        set ready 0
        return $buffer
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss method write {id bytes} {
        $context write $bytes
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss method state {} {
        $context state
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss method name {} {
        $context name
    }

# -------------------------------------------------------------------------

    oo::define ChannelGss method export {} {
        $context export
    }

# -------------------------------------------------------------------------

    oo::class create HttpConnectionGss
    oo::define HttpConnectionGss superclass HttpConnection
    oo::define HttpConnectionGss export variable
    oo::define HttpConnectionGss variable channel transform userName frontendService

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss constructor {args} {
        namespace path [list {*}[namespace path] ::srmlite::http::server]

        set argsNext [list]

        foreach {param value} $args {
            if {$param eq {-frontendService}} {
                set frontendService $value
            } else {
                lappend argsNext $param $value
            }
        }

        next {*}$argsNext
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method setup {} {
        set transform [ChannelGss new -channel $channel -connection [self]]
        if {[catch {chan create {read write} $transform} result]} {
            my log error {Error during connection setup:} $result
            my done 1
            return
        }
        set channel $result
        chan configure $channel -buffersize 16360
        chan configure $channel -blocking 0 -translation {auto crlf}
        chan event $channel readable [mymethod authorization]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method authorization {} {
        if {[$transform state] != 1} {
            my done 1
            return
        }
        my log notice {Distinguished name} [$transform name]
        if {[catch {$transform export} result]} {
            my log error $result
            my done 1
            return
        }
        chan event $channel readable {}
        $frontendService process [list authorization [self] [binary encode base64 $result]]
    }

# -------------------------------------------------------------------------

    oo::define HttpConnectionGss method authorizationSuccess {name} {
        set userName $name
        chan event $channel readable [mymethod firstLine]
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
            return
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
        regsub -all {  }   $query { {} } query ;# Othewise we lose empty values

        foreach {key val} $query {
            lappend result [decodeUrl $key] [decodeUrl $val]
        }

        return $result
    }

# -------------------------------------------------------------------------

     namespace export HttpServer HttpServerGss
}

package provide srmlite::http::server 0.2
