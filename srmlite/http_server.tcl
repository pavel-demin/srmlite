package require log
package require XOTcl

package require gssctx

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
        {address}
    }


# -------------------------------------------------------------------------

    HttpServer instproc init {} {

        my array set objectMap {}
        my array set urlCache {}

        next
    }
# -------------------------------------------------------------------------

     HttpServer instproc start {} {
        my instvar port address channel

        set myaddrOpts {}
        if {[my exists address]} {
            set myaddrOpts "-myaddr $address"
        }

        set channel [socket -server [myproc accept] {*}$myaddrOpts $port]

    }

# -------------------------------------------------------------------------

    HttpServer instproc exportObject {{-object {}} {-prefix {}}} {
        my set objectMap($prefix) $object
    }

# -------------------------------------------------------------------------

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

    HttpServer instproc accept {channel address port} {
        HttpConnection new \
            -childof [self] \
            -channel $channel \
            -address $address \
            -port $port
    }

# -------------------------------------------------------------------------

    HttpServer instproc destroy {} {
        catch {chan close [my set channel]}
        next
    }

# -------------------------------------------------------------------------

    Class HttpConnection -parameter {
        {channel}
        {address}
        {port}
        {timeout 3600000}
        {reqleft 25}
    }

# -------------------------------------------------------------------------

    HttpConnection instproc init {} {
        my reset
        my setup
        next
    }

# -------------------------------------------------------------------------

    HttpConnection instproc reset {} {
        my instvar timeout

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
        my instvar channel
        chan configure $channel -blocking 0 -buffersize 16384
        chan configure $channel -translation {auto crlf}
        chan event $channel readable [myproc firstLine]
    }

# -------------------------------------------------------------------------

    HttpConnection instproc getLine {var} {
        my upvar $var line
        my instvar channel

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

    HttpConnection instproc firstLine {} {
        my instvar channel method url query version

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
        chan event [my set channel] readable [myproc header]
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
        my instvar channel method version mime count
        variable requiresBody

        if {[my exists mime(content-length)] &&
            $mime(content-length) > 0} {
            set count $mime(content-length)
            if {$version && [my exists mime(expect)]} {
                if {$mime(expect) eq {100-continue}} {
                    chan puts $channel {100 Continue HTTP/1.1\n}
                    chan flush $channel
                } else {
                    my error 419 $mime(expect)
                    return
                }
            }
            my set postdata {}
            chan configure $channel -translation {binary crlf}
            chan event $channel readable [myproc data]
        } elseif {$requiresBody($method)} {
            my error 411 {Confusing mime headers}
            return
        } else {
            my dataDone
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc data {} {
        my instvar channel mime postdata count

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

        my append postdata $block
        set count [expr {$count - [string length $block]}]
        if {$count == 0} {
            my dataDone
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc dataDone {} {
        my dispatch
    }

# -------------------------------------------------------------------------

    HttpConnection instproc dispatch {} {
        my instvar channel method url
        variable requiresBody

        chan event $channel readable {}

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
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc respond {result} {
        my instvar channel version reqleft mime

        chan configure $channel -translation {auto crlf}

        chan puts $channel "HTTP/1.$version 200 Data follows"
        chan puts $channel "Date: [my date [clock seconds]]"
        chan puts $channel "Content-Type: text/xml; charset=utf-8"
        chan puts $channel "Content-Length: [string length $result]"

        # Should also close socket if recvd connection close header
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

    HttpConnection instproc error {code args} {
        my instvar channel url version
        variable errorFormat
        variable errorCodes

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

    HttpConnection instproc done {close} {
        my instvar channel

        after cancel [my set afterId]

        my incr reqleft -1

        if {$close} {
            my destroy
        } else {
            my reset
            chan configure $channel -translation {auto crlf}
            chan event $channel readable [myproc firstLine]
        }
    }

# -------------------------------------------------------------------------

    HttpConnection instproc destroy {} {
        my instvar channel

        catch {
            chan event $channel readable {}
            chan close $channel
        }

        next
    }

# -------------------------------------------------------------------------

    HttpConnection instproc log {level args} {
        my instvar address
        log::log $level "\[client $address\] [join $args { }]"
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

    HttpServerGss instproc accept {channel address port} {
        HttpConnectionGss new \
            -childof [self] \
            -rawchan $channel \
            -address $address \
            -port $port \
            -frontendService [my frontendService]
    }

# -------------------------------------------------------------------------

    Class ChannelGss -parameter {
        {rawchan}
    }

# -------------------------------------------------------------------------

    ChannelGss instproc init {} {
        my instvar rawchan

        my set ready 0
        my set context [gssctx $rawchan]

        next
    }

# -------------------------------------------------------------------------

    ChannelGss instproc destroy {} {
        my instvar context

        $context destroy

        next
    }

# -------------------------------------------------------------------------

    ChannelGss instproc initialize {id mode} {
        return {initialize finalize watch read write}
    }

# -------------------------------------------------------------------------

    ChannelGss instproc finalize {id} {
        my destroy
    }

# -------------------------------------------------------------------------

    ChannelGss instproc callback {id} {
        my instvar rawchan context
        set code [catch {$context read} result]
        switch -- $code {
            0 {
                my set ready 1
                my set buffer $result
                chan event $rawchan readable {}
                chan postevent $id {read}
            }
            1 {
                my set buffer {}
                chan event $rawchan readable {}
                chan postevent $id {read}
            }
        }
    }

# ---------------------------------------------------------------------

    ChannelGss instproc watch {id events} {
        my instvar rawchan ready
        if {"read" in $events} {
            if {$ready} {
                chan postevent $id {read}
            } else {
                chan event $rawchan readable [myproc callback $id]
            }
        } else {
            chan event $rawchan readable {}
        }
    }

# ---------------------------------------------------------------------

    ChannelGss instproc read {id count} {
        my instvar rawchan buffer
        chan event $rawchan readable [myproc callback $id]
        my set ready 0
        return $buffer
    }

# -------------------------------------------------------------------------

    ChannelGss instproc write {id bytes} {
        my instvar context

        $context write $bytes
    }

# -------------------------------------------------------------------------

    ChannelGss instproc state {} {
        my instvar context

        $context state
    }

# -------------------------------------------------------------------------

    ChannelGss instproc name {} {
        my instvar context

        $context name
    }

# -------------------------------------------------------------------------

    ChannelGss instproc export {} {
        my instvar context

        $context export
    }

# -------------------------------------------------------------------------

    Class HttpConnectionGss -superclass HttpConnection -parameter {
        {rawchan}
        {frontendService}
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc setup {} {
        my instvar rawchan channel transform

        chan configure $rawchan -blocking 0 -buffersize 16389
        chan configure $rawchan -translation {binary binary}

        my set transform [ChannelGss new -rawchan $rawchan]
        if {[catch {chan create {read write} $transform} result]} {
            my log error $result
            my done 1
            return
        }

        my set channel $result
        chan configure $channel -blocking 0 -buffersize 16360
        chan configure $channel -translation {auto crlf}
        chan event $channel readable [myproc authorization]
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc authorization {} {
        my instvar channel transform

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
        [my frontendService] process [list authorization [self] $result]
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc authorizationSuccess {name} {
        my instvar channel
        my set userName $name
        chan event $channel readable [myproc firstLine]
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc authorizationFailure {reason} {
        my log error {Authorization failed:} $reason
        my error 403 {Acess is not allowed}
    }

# -------------------------------------------------------------------------

    HttpConnectionGss instproc destroy {} {
        my instvar rawchan

        catch {
            chan event $rawchan readable {}
            chan close $rawchan
        }

        next
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
