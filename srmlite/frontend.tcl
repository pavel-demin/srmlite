
package require g2lite
package require gtlite
package require tdom
package require starfish

package require srmlite::templates
package require srmlite::client
package require srmlite::soap

# -------------------------------------------------------------------------

set LocalHostNames [list]

foreach interface [::starfish::netdb ip interfaces] {

    set ip [lindex $interface 1]
    if {[lsearch $LocalHostNames $ip] == -1} {lappend  LocalHostNames $ip}

    if {![catch {::starfish::netdb hosts name $ip} longName]} {
        set shortName [lindex [split $longName .] 0]
        if {[lsearch $LocalHostNames $longName] == -1} {lappend LocalHostNames $longName}
        if {[lsearch $LocalHostNames $shortName] == -1} {lappend LocalHostNames $shortName}
    }
}

# -------------------------------------------------------------------------

array set HttpdFiles {
    ./index.html 1
    ./style.css 1
}

# -------------------------------------------------------------------------

array set SoapCalls {
    getRequestStatus SrmGetRequestStatus
    setFileStatus SrmSetFileStatus
    copy SrmCopy
    get SrmGet
    put SrmPut
}

# -------------------------------------------------------------------------

set PermDict {
    rwx 7
    rw- 6
    r-x 5
    r-- 4
    -wx 3
    -w- 2
    --x 1
    --- 0
    - {}
    d {}
    l {}
    p {}
    s {}
    t {}
}

# -------------------------------------------------------------------------

proc /srm/managerv1 {sock query} {

    global errorInfo SoapCalls
    upvar #0 Httpd$sock data

    if {[info exists data(mime,soapaction)]} {
        set action $data(mime,soapaction)
    } else {
        HttpdError $sock 411 "Confusing mime headers"
        return
    }

    if {[catch {dom parse $query} document]} {
       HttpdLog $sock error $document
       return [SrmFaultBody $document $errorInfo]
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
    set argValues {}
    foreach arg [$methodNode childNodes] {
        lappend argValues [SoapDecompose $arg]
    }

    $document delete

    HttpdLog $sock notice {SOAP call} $methodName $argValues

    if {![info exists SoapCalls($methodName)]} {
        set faultString "Unknown SOAP call $methodName"
        HttpdLog $sock error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    set gssUser [fconfigure $sock -gssuser]
    set gssCert {}

    if {[string equal $methodName copy]} {
        if {[catch {fconfigure $sock -gssproxy} result]} {
            HttpdLog $sock error $result
            return [SrmFaultBody $result $errorInfo]
        } else {
            set gssCert $result
        }
    }

    if {[catch {eval [list $SoapCalls($methodName) $gssUser $gssCert] $argValues} result]} {
        HttpdLog $sock error $result
        return [SrmFaultBody $result $errorInfo]
    } else {
        return $result
    }
}

# -------------------------------------------------------------------------

proc IsLocalHost {url} {

    global LocalHostNames

    set host [lindex [ConvertSURL2HostPortFile $url] 0]

    return [expr [lsearch $LocalHostNames $host] != -1]
}

# -------------------------------------------------------------------------

proc TransferHost {} {

    global State

    # round robin scheduling
    set host [lindex $State(ftpHosts) 0]
    set State(ftpHosts) [lreplace $State(ftpHosts) 0 0]
    lappend State(ftpHosts) $host

    return $host
}

# -------------------------------------------------------------------------

proc ConvertSURL2HostPortFile {url} {
#   append exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:([0-9]+))?((} $Cfg(srmv1Prefix) | $Cfg(srmv2Prefix) {)[^/]*)?(/.*)?$}
    set exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:([0-9]+))?(/srm/managerv1[^/]*)?(/.*)?$}
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

    return "gsiftp://[TransferHost]:2811/$file"
}

# -------------------------------------------------------------------------

proc NewRequestId {} {

    global State

    return [incr State(requestId)]
}

# -------------------------------------------------------------------------

proc SrmFailed {requestId fileId errorMessage} {

    upvar #0 SrmRequest$requestId request
    upvar #0 SrmFile$fileId file

    log::log error $errorMessage

    set request(state) Failed
    set request(errorMessage) $errorMessage
    set file(state) Failed
}

# -------------------------------------------------------------------------

proc SrmReadyToGet {requestId fileId stat isRemote {srcTURL {}}} {

    global State
    upvar #0 SrmRequest$requestId request
    upvar #0 SrmFile$fileId file

    set requestType $request(requestType)

    set permMode [lindex $stat 0]
    set owner [lindex $stat 1]
    set group [lindex $stat 2]
    set size [lindex $stat 3]

    switch -- $requestType,$isRemote {
        copy,false {
            set dstSURL $file(TURL)
            regexp {srm://.*/srm/managerv1} $dstSURL serviceURL
            set call [list SrmCall $requestId $fileId $request(certProxy) $serviceURL put $dstSURL $size]
            set request(afterId) [after 0 $call]
        }
        copy,true {
#            set request(state) Active
#            set file(state) Ready
            set dstTURL [ConvertSURL2TURL $file(TURL)]
            puts $State(in) [list copy $requestId $fileId $request(userName) $request(certProxy) $srcTURL $dstTURL]
        }
        get,false {
            set request(state) Active
            set file(state) Ready
            set file(TURL) [ConvertSURL2TURL $file(SURL)]
            array set file [list isPinned true isPermanent true isCached true]
        }
    }

    set request(retryDeltaTime) 4
    array set file [list size $size owner $owner group $group permMode $permMode]
}

# -------------------------------------------------------------------------

proc SrmReadyToPut {requestId fileId isRemote {dstTURL {}}} {

    global State
    upvar #0 SrmRequest$requestId request
    upvar #0 SrmFile$fileId file

    set requestType $request(requestType)

    switch -- $requestType,$isRemote {
        copy,false {
            set srcSURL $file(SURL)
            regexp {srm://.*/srm/managerv1} $srcSURL serviceURL
            set call [list SrmCall $requestId $fileId $request(certProxy) $serviceURL get $srcSURL]
            set request(afterId) [after 0 $call]
        }
        copy,true {
#            set request(state) Active
#            set file(state) Ready
            set srcTURL [ConvertSURL2TURL $file(SURL)]
            puts $State(in) [list copy $requestId $fileId $request(userName) $request(certProxy) $srcTURL $dstTURL]
        }
        put,false {
            set request(state) Active
            set file(state) Ready
            set file(TURL) [ConvertSURL2TURL $file(srcSURL)]
        }
    }

    set request(retryDeltaTime) 4
}

# -------------------------------------------------------------------------

proc SrmCopyDone {requestId fileId} {

    upvar #0 SrmRequest$requestId request
    upvar #0 SrmFile$fileId file

    set request(state) Done
    set file(state) Done
}

# -------------------------------------------------------------------------

proc SrmSubmitTask {userName certProxy requestType requestId fileId SURL {dstSURL {}} {size 0}} {

    global State SrmRequestTimer
    upvar #0 SrmFile$fileId file
    upvar #0 SrmRequest$requestId request

    set clockStart [clock seconds]
    set clockFinish [clock scan {1 hour} -base $clockStart]

    set submitTime [clock format $clockStart -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]
    set startTime $submitTime
    set finishTime [clock format $clockFinish -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]

    array set request [list state Pending requestType $requestType fileId $fileId]
    array set request [list submitTime $submitTime startTime $startTime finishTime $finishTime]
    array set request [list errorMessage {} retryDeltaTime 1 counter 1]
    array set request [list afterId {} userName $userName certProxy $certProxy]
    array set file [list retryDeltaTime 1 state Pending requestId $requestId]
    array set file [list size $size owner {} group {} permMode 0]
    array set file [list isPinned false isPermanent false isCached false]
    array set file [list SURL $SURL TURL $dstSURL]

    set SrmRequestTimer($requestId) -1

    switch -- $requestType {
        get -
        put {
            puts $State(in) [list $requestType $requestId $fileId $userName $certProxy $SURL]
        }
        copy {
            if {[IsLocalHost $SURL] && ![IsLocalHost $dstSURL]} {
                puts $State(in) [list get $requestId $fileId $userName $certProxy $SURL]
            } elseif {![IsLocalHost $SURL] && [IsLocalHost $dstSURL]} {
                puts $State(in) [list put $requestId $fileId $userName $certProxy $dstSURL]
            } else {
                SrmFailed $requestId $fileId {copying between two local or two remote SURLs is not allowed}
            }
        }
    }


    return [SrmGetRequestStatus $userName $certProxy $requestId $requestType]
}

# -------------------------------------------------------------------------

proc SrmGetRequestStatus {userName certProxy requestId {requestType getRequestStatus}} {

    global State
    upvar #0 SrmRequest$requestId request

    log::log debug "SrmGetRequestStatus $requestId [info exists request]"
    if {![info exists request]} {
       set faultString "Unknown request id $requestId"
       return [SrmFaultBody $faultString $faultString]
    }

    set fileId $request(fileId)
    upvar #0 SrmFile$fileId file

    if {![string equal $request(userName) $userName]} {
        SrmFailed $requestId $fileId "user $userName does not have permission to access request $requestId"
    }

    set counter [incr request(counter)]
    if {$counter > 15} {
        set request(retryDeltaTime) 16
    } elseif {$counter > 12} {
        set request(retryDeltaTime) 13
    } elseif {$counter > 9} {
        set request(retryDeltaTime) 10
    } elseif {$counter > 6} {
        set request(retryDeltaTime) 7
    } elseif {$counter > 3} {
        set request(retryDeltaTime) 4
    }

    return [SrmStatusBody $requestType $requestId $request(state) \
                          $request(retryDeltaTime) $request(submitTime) \
                          $request(startTime) $request(finishTime) \
                          $file(SURL) $file(size) $file(owner) $file(group) $file(permMode) \
                          $file(isPinned) $file(isPermanent) $file(isCached) \
                          $file(state) $fileId $file(TURL) $request(errorMessage)]

}

# -------------------------------------------------------------------------

proc SrmSetFileStatus {userName certProxy requestId fileId fileState} {

    global State
    upvar #0 SrmRequest$requestId request

    if {![info exists request]} {
       set faultString "Unknown request id $requestId"
       return [SrmFaultBody $faultString $faultString]
    }

    upvar #0 SrmFile$fileId file

    if {![info exists file]} {
       set faultString "Unknown file id $fileId"
       return [SrmFaultBody $faultString $faultString]
    }

    set requestType $request(requestType)

    set request(state) $fileState
    set file(state) $fileState

    if {[string equal $request(userName) $userName]} {
        if {$fileState == "Done" && $requestType != "copy"} {
            puts $State(in) [list stop $requestId $fileId $request(userName) $request(certProxy)]
        }
    } else {
        SrmFailed $requestId $fileId "user $userName does not have permission to update request $requestId"
    }

    return [SrmStatusBody setFileStatus $requestId $request(state) \
                          $request(retryDeltaTime) $request(submitTime) \
                          $request(startTime) $request(finishTime) \
                          $file(SURL) $file(size) $file(owner) $file(group) $file(permMode) \
                          $file(isPinned) $file(isPermanent) $file(isCached) \
                          $file(state) $fileId $file(TURL) $request(errorMessage)]
}

# -------------------------------------------------------------------------

proc SrmCopy {userName certProxy srcSURL dstSURL dummy} {

    set requestId [NewRequestId]
    set fileId [NewRequestId]

    return [SrmSubmitTask $userName $certProxy copy $requestId $fileId $srcSURL $dstSURL]
}

# -------------------------------------------------------------------------

proc SrmGet {userName certProxy srcSURL protocols} {

    set requestId [NewRequestId]
    set fileId [NewRequestId]

    return [SrmSubmitTask $userName $certProxy get $requestId $fileId $srcSURL]
}

# -------------------------------------------------------------------------

proc SrmPut {userName certProxy srcSURL dstSURL size wantPermanent protocols} {

    set requestId [NewRequestId]
    set fileId [NewRequestId]

    return [SrmSubmitTask $userName $certProxy put $requestId $fileId $srcSURL $dstSURL $size]
}

# -------------------------------------------------------------------------

proc SrmTimeout {seconds} {
    global SrmRequestTimer

    log::log debug "SrmTimeout $seconds"

    foreach requestId [array names SrmRequestTimer] {
        set counter [incr SrmRequestTimer($requestId)]
        if {$counter > 5} {
            after 0 [list KillSrmRequest $requestId]
        }
    }
    alarm $seconds
}

# -------------------------------------------------------------------------

proc KillSrmRequest {requestId} {

    global State SrmRequestTimer
    upvar #0 SrmRequest$requestId request

    if {[info exists SrmRequestTimer($requestId)]} {
        unset SrmRequestTimer($requestId)
    }

    if {[info exists request]} {
        set fileId $request(fileId)
        upvar #0 SrmFile$fileId file

        puts $State(in) [list stop $requestId $fileId $request(userName) $request(certProxy)]

        if {[info exists file]} {
            unset file
        }
        unset request
    }
}

# -------------------------------------------------------------------------

proc GetInput {chan} {

    global PermDict

    if {[catch {gets $chan line} readCount]} {
        log::log error $readCount
        close $chan
        return
    }

    if {$readCount == -1} {
        if {[eof $sock]} {
            log::log error {Broken connection fetching request}
            close $chan
        } else {
            log::log warning {No full line available, retrying...}
        }
        return
    }

    set state [lindex $line 0]
    set requestType [lindex $line 1]
    set requestId [lindex $line 2]
    set fileId [lindex $line 3]
    set output [lindex $line 4]

    switch -glob -- $state,$requestType {
        Failed,* {
            SrmFailed $requestId $fileId $output
        }
        Ready,get {
            set permMode [string map $PermDict [lindex $output 0]]
            set stat [lreplace $output 0 1 $permMode]
            SrmReadyToGet $requestId $fileId $stat false
        }
        Ready,put {
            SrmReadyToPut $requestId $fileId false
        }
        Done,copy {
            SrmCopyDone $requestId $fileId
        }
    }

    log::log debug $line
}

# -------------------------------------------------------------------------

package provide srmlite::frontend 0.1

