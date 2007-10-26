
package require g2lite
package require gtlite
package require dict
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

proc SrmReadyToGet {fileId stat isRemote {srcTURL {}}} {

    global State

    upvar #0 SrmFiles($fileId) file

    set SURL [dict get $file SURL]
    set TURL [dict get $file TURL]
    set requestId [dict get $file requestId]

    upvar #0 SrmRequests($requestId) request

    set requestType [dict get $request requestType]
    set userName [dict get $request userName]
    set certProxy [dict get $request certProxy]

    switch -- $requestType,$isRemote {
        copy,false {
            set dstSURL $TURL
            regexp {srm://.*/srm/managerv1} $dstSURL serviceURL
            set call [list SrmCall $fileId $serviceURL put $dstSURL $size]
            after 0 $call
        }
        copy,true {
#            SrmSetState $requestId $fileId Ready
            set dstTURL [ConvertSURL2TURL $TURL]
            puts $State(in) [list copy $fileId $userName $certProxy $srcTURL $dstTURL]
        }
        get,false {
            dict set file TURL [ConvertSURL2TURL $SURL]
            dict set file isPinned true
            dict set file isPermanent true
            dict set file isCached true
            SrmSetState $requestId $fileId Ready
        }
    }

    dict set file permMode [lindex $stat 0]
    dict set file owner [lindex $stat 1]
    dict set file group [lindex $stat 2]
    dict set file size [lindex $stat 3]
}

# -------------------------------------------------------------------------

proc SrmReadyToPut {fileId isRemote {dstTURL {}}} {

    global State

    upvar #0 SrmFiles($fileId) file

    set SURL [dict get $file SURL]
    set TURL [dict get $file TURL]
    set requestId [dict get $file requestId]

    upvar #0 SrmRequests($requestId) request

    set requestType [dict get $request requestType]
    set userName [dict get $request userName]
    set certProxy [dict get $request certProxy]

    switch -- $requestType,$isRemote {
        copy,false {
            set srcSURL $SURL
            regexp {srm://.*/srm/managerv1} $srcSURL serviceURL
            set call [list SrmCall $fileId $serviceURL get $srcSURL]
            after 0 $call
        }
        copy,true {
#            SrmSetState $requestId $fileId Ready
            set srcTURL [ConvertSURL2TURL $SURL]
            puts $State(in) [list copy $fileId $userName $certProxy $srcTURL $dstTURL]
        }
        put,false {
            dict set file TURL [ConvertSURL2TURL $SURL]
            SrmSetState $requestId $fileId Ready
        }
    }
}

# -------------------------------------------------------------------------

proc SrmCopyDone {fileId} {

    upvar #0 SrmFiles($fileId) file

    set requestId [dict get $file requestId]

    SrmSetState $requestId $fileId Done
}

# -------------------------------------------------------------------------

proc SrmSubmitTask {userName certProxy requestType SURLS {dstSURLS {}} {sizes {}}} {

    global State

    set requestId [NewRequestId]
    upvar #0 SrmRequests($requestId) request
    upvar #0 SrmRequestTimer($requestId) timer

    set clockStart [clock seconds]
    set clockFinish [clock scan {1 hour} -base $clockStart]

    set submitTime [clock format $clockStart -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]
    set startTime $submitTime
    set finishTime [clock format $clockFinish -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]

    set request [dict create reqState Pending requestType $requestType \
        submitTime $submitTime startTime $startTime finishTime $finishTime \
        errorMessage {} retryDeltaTime 1 fileIds {} counter 1 \
        userName $userName certProxy $certProxy]

    foreach SURL $SURLS dstSURL $dstSURLS size $sizes {

        set fileId [NewRequestId]
        upvar #0 SrmFiles($fileId) file

        if {$size == {}} {
            set size 0
        }

        set file [dict create state Pending requestId $requestId \
            size $size owner {} group {} permMode 0 \
            isPinned false isPermanent false isCached false \
            SURL $SURL TURL $dstSURL]

        dict lappend request fileIds $fileId

        switch -- $requestType {
            get -
            put {
                puts $State(in) [list $requestType $fileId $userName $certProxy $SURL]
            }
            copy {
                if {[IsLocalHost $SURL] && ![IsLocalHost $dstSURL]} {
                    puts $State(in) [list get $fileId $userName $certProxy $SURL]
                } elseif {![IsLocalHost $SURL] && [IsLocalHost $dstSURL]} {
                    puts $State(in) [list put $fileId $userName $certProxy $dstSURL]
                } else {
                    SrmFailed $fileId {copying between two local or two remote SURLs is not allowed}
                }
            }
        }
    }

    set timer -1

    return [SrmGetRequestStatus $userName $certProxy $requestId $requestType]
}

# -------------------------------------------------------------------------

proc SrmGetRequestStatus {userName certProxy requestId {requestType getRequestStatus}} {

    global State
    upvar #0 SrmRequests($requestId) request

    if {![info exists request]} {
        set faultString "Unknown request id $requestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    set requestUserName [dict get $request userName]

    if {![string equal $requestUserName $userName]} {
        set faultString "User $userName does not have permission to access request $requestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    set counter [dict get $request counter]
    incr counter

    dict set request counter $counter
    dict set request retryDeltaTime [expr {$counter / 4 * 5 + 1}]

    return [SrmStatusBody $requestType $requestId]
}

# -------------------------------------------------------------------------

proc SrmSetFileStatus {userName certProxy requestId fileId newState} {

    global SrmRequests SrmFiles
    upvar #0 SrmRequests($requestId) request
    upvar #0 SrmFiles($fileId) file

    if {![info exists request]} {
        set faultString "Unknown request id $requestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    if {![info exists file]} {
        set faultString "Unknown file id $fileId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    set fileIds [dict get $request fileIds]

    if {[lsearch $fileIds $fileId] == -1} {
        set faultString "File $fileId is not part of request $requestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    set requestUserName [dict get $request userName]

    if {![string equal $requestUserName $userName]} {
        set faultString "User $userName does not have permission to update request $requestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    SrmSetState $requestId $fileId $newState

    return [SrmStatusBody setFileStatus $requestId]
}

# -------------------------------------------------------------------------

proc SrmSetState {requestId fileId newState} {

    global State
    upvar #0 SrmRequests($requestId) request
    upvar #0 SrmFiles($fileId) file


    set requestType [dict get $request requestType]
    set requestState [dict get $request reqState]
    set currentState [dict get $file state]

    log::log debug "SrmSetState $requestId $fileId $requestState,$currentState,$newState"

    switch -glob -- $requestState,$currentState,$newState {
        Pending,Pending,Ready -
        Active,Pending,Ready {
            dict set request reqState Active
            dict set file state Ready
        }
        Pending,Ready,Running -
        Active,Ready,Running {
            dict set request reqState Active
            dict set file state Running
        }
        Pending,Pending,Done -
        Pending,Ready,Done -
        Active,Pending,Done -
        Active,Running,Done -
        Active,Ready,Done {
            dict set file state Done
            if {[SrmIsRequestDone $requestId]} {
                dict set request reqState Done
            }
            puts $State(in) [list stop $fileId]
            if {$requestType == "copy"} {
                SrmCallStop $fileId
            }
        }
        *,*,Failed {
            dict set request reqState Failed
            dict set file state Failed
            puts $State(in) [list stop $fileId]
            if {$requestType == "copy"} {
                SrmCallStop $fileId
            }
        }
        default {
            log::log error "Unexpected state $requestState,$currentState,$newState"
        }
    }
}

# -------------------------------------------------------------------------

proc SrmFailed {fileId errorMessage} {

    upvar #0 SrmFiles($fileId) file
    set requestId [dict get $file requestId]
    upvar #0 SrmRequests($requestId) request

    log::log error $errorMessage

    dict set request errorMessage $errorMessage
    dict set request reqState Failed
    dict set file state Failed
}

# -------------------------------------------------------------------------

proc SrmIsRequestDone {requestId} {

    global SrmFiles SrmRequests

    foreach fileId [dict get $SrmRequests($requestId) fileIds] {
        if {[dict get $SrmFiles($fileId) state] != "Done"} {
            return 0
        }
    }

    return 1
}

# -------------------------------------------------------------------------

proc SrmCopy {userName certProxy srcSURLS dstSURLS dummy} {

    return [SrmSubmitTask $userName $certProxy copy $srcSURLS $dstSURLS]
}

# -------------------------------------------------------------------------

proc SrmGet {userName certProxy srcSURLS protocols} {

    return [SrmSubmitTask $userName $certProxy get $srcSURLS]
}

# -------------------------------------------------------------------------

proc SrmPut {userName certProxy srcSURLS dstSURLS sizes wantPermanent protocols} {

    return [SrmSubmitTask $userName $certProxy put $srcSURLS $dstSURLS $sizes]
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

    global State
    upvar #0 SrmRequests($requestId) request
    upvar #0 SrmRequestTimer($requestId) timer

    if {[info exists timer]} {
        unset timer
    }

    if {[info exists request]} {
        foreach fileId [dict get $request fileIds] {
            upvar #0 SrmFiles($fileId) file

            puts $State(in) [list stop $fileId]

            if {[info exists file]} {
                unset file
            }
            unset request
        }
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
    set fileId [lindex $line 2]
    set output [lindex $line 3]

    switch -glob -- $state,$requestType {
        Failed,* {
            SrmFailed $fileId $output
        }
        Ready,get {
            set permMode [string map $PermDict [lindex $output 0]]
            set stat [lreplace $output 0 1 $permMode]
            SrmReadyToGet $fileId $stat false
        }
        Ready,put {
            SrmReadyToPut $fileId false
        }
        Done,copy {
            SrmCopyDone $fileId
        }
    }

    log::log debug $line
}

# -------------------------------------------------------------------------

package provide srmlite::frontend 0.1


