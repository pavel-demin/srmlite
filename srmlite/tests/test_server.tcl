lappend auto_path .

package require log

package require gss::socket
package require srmlite::httpd

package require srmlite::templates
package require srmlite::soap

# -------------------------------------------------------------------------

set StateDict {
    Pending     SRM_REQUEST_QUEUED
}

# -------------------------------------------------------------------------

proc ConvertSURL2HostPortFile {url} {
#   append exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:([0-9]+))?((} $Cfg(srmv1Prefix) | $Cfg(srmv2Prefix) {)[^/]*)?(/.*)?$}
    set exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:([0-9]+))?(/srm/managerv2[^/]*)?(/.*)?$}
    if {![regexp -nocase $exp $url x prefix proto user host y port z file]} {
        log::log error "Unsupported URL $url"
        return {}
    }

    set file [file normalize $file]
    return [list $host $port $file]
}

# -------------------------------------------------------------------------

proc ConvertSURL2TURL {url} {

    set file [lindex [ConvertSURL2HostPortFile $url] 2]

    return "gsiftp://ingrid-se01.cism.ucl.ac.be:2811/$file"
}

# -------------------------------------------------------------------------

proc /srm/managerv2 {sock requestId query} {
    upvar #0 Httpd$sock data

    if {[info exists data(mime,soapaction)]} {
        set action $data(mime,soapaction)
    } else {
        HttpdError $sock 411 "Confusing mime headers"
        return
    }

    if {[catch {dom parse $query} document]} {
       HttpdLog $sock error $document
       HttpdResult $sock [SrmFaultBody $document $errorInfo]
       return
    }

    set root [$document documentElement]

    set ns {soap http://schemas.xmlsoap.org/soap/envelope/}

    # Check SOAP version by examining the namespace of the Envelope elt.
    set envelopeNode [$root selectNodes -namespaces $ns {/soap:Envelope}]

    # Get the method name from the XML request.
    # Ensure we only select the first child element
    set methodNode [$root selectNodes -namespaces $ns {/soap:Envelope/soap:Body/*[1]}]
    set methodName [$methodNode localName]

    # Extract the parameters.

    set methodDict [SoapDecompose $methodNode]

    $document delete

    puts "SOAP call $methodName $methodDict"

    set result [dict get $methodDict ${methodName}Request]

    set arrayOfFileRequests [dict get $result arrayOfFileRequests]

    foreach fileRequest $arrayOfFileRequests {

      puts $fileRequest

      lappend srcSURLS [dict get $fileRequest sourceSURL]
    }
    if {[catch {CreateRequest $srcSURLS} requestId]} {
       puts $requestId
       return
    }

    if {[catch {Srm2StatusBody $methodName $requestId} query]} {
       puts $query
       return
    }

    HttpdResult $sock $query

}

proc CreateRequest {SURLS} {

    set clockStart [clock seconds]
    set clockFinish [clock scan {2 hours} -base $clockStart]

    set submitTime [clock format $clockStart -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]
    set startTime $submitTime
    set finishTime [clock format $clockFinish -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]

    set requestId [HttpdNewRequestId]

    upvar #0 SrmRequest$requestId request

    set request [dict create userName {} reqState SRM_SUCCESS requestType {} \
        submitTime $submitTime startTime $startTime finishTime $finishTime \
        errorMessage {} retryDeltaTime 1 fileIds {} counter 1]

    foreach srcSURL $SURLS {
        set fileId [HttpdNewRequestId]

        upvar #0 SrmFile$fileId file

        set file [dict create state SRM_FILE_PINNED requestId $requestId \
            size 2500477056 owner {} group {} permMode 0 \
            isPinned false isPermanent false isCached false \
            pinDeltaTime 7200 SURL $srcSURL TURL [ConvertSURL2TURL $srcSURL]]

        dict lappend request fileIds $fileId
    }
    return $requestId
}

HttpdServer . 8443 index.html

vwait forever
