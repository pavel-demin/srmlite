
package require gss::socket
package require g2lite
package require dict
package require tdom
package require starfish

package require srmlite::templates
package require srmlite::gridftp
package require srmlite::client
package require srmlite::soap

# -------------------------------------------------------------------------

set SrmRequestTimer [dict create]

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

array set SoapOffLineCalls {
    getRequestStatus SrmGetRequestStatus
    setFileStatus SrmSetFileStatus
    advisoryDelete SrmAdvisoryDelete
    ping SrmPing
    copy SrmCopy
    get SrmGet
    put SrmPut
}

# -------------------------------------------------------------------------

array set SoapOnLineCalls {
    getFileMetaData SrmGetFileMetaData
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

proc /srm/managerv1 {sock requestId query} {

    if {[catch {SrmGetUserName $sock $requestId $query} result]} {
        HttpdLog $sock error $result
        HttpdError $sock 403 "Acess is not allowed"
        return
    }
}

# -------------------------------------------------------------------------

proc SrmGetUserName {sock requestId query} {

    global State SrmRequestTimer

    set gssContext [fconfigure $sock -gsscontext]

    upvar #0 SrmRequest$requestId request

    set clockStart [clock seconds]
    set clockFinish [clock scan {2 hours} -base $clockStart]

    set submitTime [clock format $clockStart -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]
    set startTime $submitTime
    set finishTime [clock format $clockFinish -format {%Y-%m-%dT%H:%M:%SZ} -gmt yes]

    set request [dict create socket $sock query $query userName {} \
        reqState Pending requestType {} \
        submitTime $submitTime startTime $startTime finishTime $finishTime \
        errorMessage {} retryDeltaTime 1 fileIds {} counter 1]

    dict set SrmRequestTimer $requestId 0

    puts $State(in) [list getUserName $requestId $gssContext]
}

# -------------------------------------------------------------------------

proc SrmUserNameFailed {requestId userName} {

    upvar #0 SrmRequest$requestId request

    if {![info exists request]} {
        set faultString "SrmUserNameFailed: unknown request id $requestId"
        log::log error $faultString
        return
    }

    set sock [dict get $request socket]

    HttpdError $sock 403 "Acess is not allowed"

#    KillSrmRequest $requestId
}

# -------------------------------------------------------------------------

proc SrmUserNameReady {requestId userName} {

    global errorInfo SoapOffLineCalls SoapOnLineCalls
    upvar #0 SrmRequest$requestId request

    if {![info exists request]} {
        set faultString "SrmUserNameReady: unknown request id $requestId"
        log::log error $faultString
        return
    }

    dict set request userName $userName

    set sock [dict get $request socket]
    set query [dict get $request query]

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
    set argValues {}
    foreach arg [$methodNode childNodes] {
        lappend argValues [SoapDecompose $arg]
    }

    $document delete

    HttpdLog $sock notice {SOAP call} $methodName $argValues

    if {[info exists SoapOffLineCalls($methodName)]} {
        if {[catch {eval [list $SoapOffLineCalls($methodName) $requestId] $argValues} result]} {
            HttpdLog $sock error $result
            HttpdResult $sock [SrmFaultBody $result $errorInfo]
            return
        } else {
            HttpdResult $sock $result
            return
        }
    } elseif {[info exists SoapOnLineCalls($methodName)]} {
        if {[catch {eval [list $SoapOnLineCalls($methodName) $requestId] $argValues} result]} {
            HttpdLog $sock error $result
            HttpdResult $sock [SrmFaultBody $result $errorInfo]
            return
        }
    } else {
        set faultString "Unknown SOAP call $methodName"
        HttpdLog $sock error $faultString
        HttpdResult $sock [SrmFaultBody $faultString $faultString]
        return
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

proc SrmReadyToGet {fileId stat isRemote {srcTURL {}}} {

    global State

    upvar #0 SrmFile$fileId file

    set SURL [dict get $file SURL]
    set TURL [dict get $file TURL]
    set certProxy [dict get $file certProxy]
    set requestId [dict get $file requestId]

    upvar #0 SrmRequest$requestId request

    set requestType [dict get $request requestType]
    set userName [dict get $request userName]

    dict set file permMode [lindex $stat 0]
    dict set file owner [lindex $stat 1]
    dict set file group [lindex $stat 2]
    dict set file size [lindex $stat 3]

    switch -- $requestType,$isRemote {
        copy,false {
            set dstSURL $TURL
            set size [lindex $stat 3]
            set dstSURL [string map {managerv2 managerv1} $dstSURL]
            regexp {srm://.*/srm/managerv1} $dstSURL serviceURL
            set call [list SrmCall $fileId $serviceURL put $dstSURL $size]
            dict set file afterId [after 0 $call]
        }
        copy,true {
#            SrmSetState $requestId $fileId Ready
            set dstTURL [ConvertSURL2TURL $TURL]
            GridFtpCopy $fileId $srcTURL $dstTURL
        }
        get,false {
            dict set file TURL [ConvertSURL2TURL $SURL]
            dict set file isPinned true
            dict set file isPermanent true
            dict set file isCached true
            SrmSetState $requestId $fileId Ready
        }
        getFileMetaData,false {
            dict set file isPinned true
            dict set file isPermanent true
            dict set file isCached true
            SrmSetState $requestId $fileId Done
        }
    }
}

# -------------------------------------------------------------------------

proc SrmReadyToPut {fileId isRemote {dstTURL {}}} {

    global State

    upvar #0 SrmFile$fileId file

    set SURL [dict get $file SURL]
    set TURL [dict get $file TURL]
    set certProxy [dict get $file certProxy]
    set requestId [dict get $file requestId]

    upvar #0 SrmRequest$requestId request

    set requestType [dict get $request requestType]
    set userName [dict get $request userName]

    switch -- $requestType,$isRemote {
        copy,false {
            set srcSURL $SURL
            set srcSURL [string map {managerv2 managerv1} $srcSURL]
            regexp {srm://.*/srm/managerv1} $srcSURL serviceURL
            set call [list SrmCall $fileId $serviceURL get $srcSURL]
            dict set file afterId [after 0 $call]
        }
        copy,true {
#            SrmSetState $requestId $fileId Ready
            set srcTURL [ConvertSURL2TURL $SURL]
            GridFtpCopy $fileId $srcTURL $dstTURL
        }
        put,false {
            dict set file TURL [ConvertSURL2TURL $SURL]
            SrmSetState $requestId $fileId Ready
        }
    }
}

# -------------------------------------------------------------------------

proc SrmCopyDone {fileId} {

    upvar #0 SrmFile$fileId file

    set requestId [dict get $file requestId]

    SrmSetState $requestId $fileId Ready
}

# -------------------------------------------------------------------------

proc SrmDeleteDone {fileId} {

    upvar #0 SrmFile$fileId file

    set requestId [dict get $file requestId]

    SrmSetState $requestId $fileId Done
}

# -------------------------------------------------------------------------

proc SrmCreateRequest {requestId requestType SURLS {dstSURLS {}} {sizes {}} {certProxies {}}} {

    global State

    upvar #0 SrmRequest$requestId request

    dict set request requestType $requestType

    set userName [dict get $request userName]

    foreach SURL $SURLS dstSURL $dstSURLS size $sizes certProxy $certProxies {

        set fileId [HttpdNewRequestId]
        upvar #0 SrmFile$fileId file

        if {$size == {}} {
            set size 0
        }

        set file [dict create state Pending requestId $requestId \
            size $size owner {} group {} permMode 0 \
            isPinned false isPermanent false isCached false \
            SURL $SURL TURL $dstSURL certProxy $certProxy afterId {}]

        dict lappend request fileIds $fileId

        switch -- $requestType {
            get -
            put -
            advisoryDelete {
                puts $State(in) [list $requestType $fileId $userName $SURL]
            }
            getFileMetaData {
                puts $State(in) [list get $fileId $userName $SURL]
            }
            copy {
                if {[IsLocalHost $SURL] && ![IsLocalHost $dstSURL]} {
                    puts $State(in) [list get $fileId $userName $SURL]
                } elseif {![IsLocalHost $SURL] && [IsLocalHost $dstSURL]} {
                    puts $State(in) [list put $fileId $userName $dstSURL]
                } else {
                    SrmFailed $fileId {copying between two local or two remote SURLs is not allowed}
                }
            }
        }
    }
}

# -------------------------------------------------------------------------

proc SrmSubmitTask {requestId requestType SURLS {dstSURLS {}} {sizes {}} {certProxies {}}} {

    SrmCreateRequest $requestId $requestType $SURLS $dstSURLS $sizes $certProxies

    return [SrmGetRequestStatus $requestId $requestId $requestType]
}

# -------------------------------------------------------------------------

proc SrmGetFileMetaData {requestId SURLS} {

    SrmCreateRequest $requestId getFileMetaData $SURLS
}

# -------------------------------------------------------------------------

proc SrmFileMetaDataReady {requestId} {

    global State
    upvar #0 SrmRequest$requestId request

    set sock [dict get $request socket]
    set requestState [dict get $request reqState]

    switch -glob -- $requestState {
        Failed {
            set faultString [dict get $request errorMessage]
            HttpdResult $sock [SrmFaultBody $faultString $faultString]
        }
        Done {
            HttpdResult $sock [SrmFileMetaDataBody $requestId]
        }
    }

    KillSrmRequest $requestId
}

# -------------------------------------------------------------------------

proc SrmGetRequestStatus {requestId inputRequestId {inputRequestType getRequestStatus}} {

    global State
    upvar #0 SrmRequest$inputRequestId inputRequest

    if {![info exists inputRequest]} {
        set faultString "Unknown request id $inputRequestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    upvar #0 SrmRequest$requestId request

    set inputUserName [dict get $inputRequest userName]
    set userName [dict get $request userName]

    if {![string equal $inputUserName $userName]} {
        set faultString "User $inputUserName does not have permission to access request $inputRequestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    set counter [dict get $inputRequest counter]
    incr counter

    dict set inputRequest counter $counter
    dict set inputRequest retryDeltaTime [expr {$counter / 4 * 5 + 1}]

    return [SrmStatusBody $inputRequestType $inputRequestId]
}

# -------------------------------------------------------------------------

proc SrmSetFileStatus {requestId inputRequestId inputFileId newState} {

    upvar #0 SrmRequest$inputRequestId inputRequest
    upvar #0 SrmFile$inputFileId inputFile

    if {![info exists inputRequest]} {
        set faultString "Unknown request id $inputRequestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    if {![info exists inputFile]} {
        set faultString "Unknown file id $inputFileId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    set fileIds [dict get $inputRequest fileIds]

    if {[lsearch $fileIds $inputFileId] == -1} {
        set faultString "File $inputFileId is not part of request $inputRequestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    upvar #0 SrmRequest$requestId request

    set inputUserName [dict get $inputRequest userName]
    set userName [dict get $request userName]

    if {![string equal $inputUserName $userName]} {
        set faultString "User $inputUserName does not have permission to update request $inputRequestId"
        log::log error $faultString
        return [SrmFaultBody $faultString $faultString]
    }

    SrmSetState $inputRequestId $inputFileId $newState

    return [SrmStatusBody setFileStatus $inputRequestId]
}

# -------------------------------------------------------------------------

proc SrmSetState {requestId fileId newState} {

    global State
    upvar #0 SrmRequest$requestId request
    upvar #0 SrmFile$fileId file


    set requestType [dict get $request requestType]
    set requestState [dict get $request reqState]
    set currentState [dict get $file state]

    log::log debug "SrmSetState $requestId $fileId $requestState,$currentState,$newState"

    switch -glob -- $requestState,$currentState,$newState {
        Pending,Pending,Ready -
        Active,Pending,Ready {
            dict set request reqState Active
            dict set file state Ready
            if {[string equal $requestType copy]} {
                SrmCallStop $fileId
                GridFtpStop $fileId
            }
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
        Active,Ready,Done -
        Failed,Pending,Done -
        Failed,Running,Done -
        Failed,Ready,Done -
        Failed,Failed,Done {
            dict set file state Done
            if {[SrmIsRequestDone $requestId]} {
                dict set request reqState Done
                if {[string equal $requestType getFileMetaData]} {
                    SrmFileMetaDataReady $requestId
                }
            }
            if {[string equal $requestType copy]} {
                SrmCallStop $fileId
                GridFtpStop $fileId
            }
        }
        *,*,Failed {
            dict set request reqState Failed
            dict set file state Failed
            if {[string equal $requestType copy]} {
                SrmCallStop $fileId
                GridFtpStop $fileId
            }
        }
        default {
            log::log error "Unexpected state $requestState,$currentState,$newState"
        }
    }
}

# -------------------------------------------------------------------------

proc SrmFailed {fileId errorMessage} {

    log::log error "SrmFailed: $errorMessage"

    upvar #0 SrmFile$fileId file

    if {![info exists file]} {
        set faultString "SrmFailed: unknown file id $fileId"
        log::log error $faultString
        return
    }

    set requestId [dict get $file requestId]
    upvar #0 SrmRequest$requestId request

    if {![info exists request]} {
        set faultString "SrmFailed: unknown request id $requestId"
        log::log error $faultString
        return
    }

    dict set request errorMessage $errorMessage

    SrmSetState $requestId $fileId Failed


    set requestType [dict get $request requestType]
    set sock [dict get $request socket]

    if {[string equal $requestType getFileMetaData]} {
        HttpdResult $sock [SrmFaultBody $errorMessage $errorMessage]
    }
}

# -------------------------------------------------------------------------

proc SrmIsRequestDone {requestId} {

    upvar #0 SrmRequest$requestId request

    foreach fileId [dict get $request fileIds] {
        upvar #0 SrmFile$fileId file
        if {[dict get $file state] != "Done"} {
            return 0
        }
    }

    return 1
}

# -------------------------------------------------------------------------

proc SrmAdvisoryDelete {requestId srcSURLS} {

    return [SrmSubmitTask $requestId advisoryDelete $srcSURLS]
}

# -------------------------------------------------------------------------

proc SrmPing {requestId} {

    return [SrmPingResponseBody]
}

# -------------------------------------------------------------------------

proc SrmCopy {requestId srcSURLS dstSURLS dummy} {

    upvar #0 SrmRequest$requestId request

    set sock [dict get $request socket]

    set certProxies [list]

    foreach SURL $srcSURLS {
      if {[catch {fconfigure $sock -gssexport} result]} {
          HttpdLog $sock error $result
          foreach proxy $certProxies {
              $proxy destroy
          }
          return [SrmFaultBody $result $errorInfo]
      } else {
          log::log debug "new certProxy $result"
          lappend certProxies $result
      }
    }

    return [SrmSubmitTask $requestId copy $srcSURLS $dstSURLS {} $certProxies]
}

# -------------------------------------------------------------------------

proc SrmGet {requestId srcSURLS protocols} {

    return [SrmSubmitTask $requestId get $srcSURLS]
}

# -------------------------------------------------------------------------

proc SrmPut {requestId srcSURLS dstSURLS sizes wantPermanent protocols} {

    return [SrmSubmitTask $requestId put $srcSURLS $dstSURLS $sizes]
}

# -------------------------------------------------------------------------

proc SrmTimeout {seconds} {

    global Cfg SrmRequestTimer

    log::log debug "SrmTimeout $seconds"

    LogRotate $Cfg(frontendLog)

    dict for {requestId counter} $SrmRequestTimer {
        dict incr SrmRequestTimer $requestId
        if {$counter > 15} {
            after 0 [list KillSrmRequest $requestId]
        }
    }
    alarm $seconds
}

# -------------------------------------------------------------------------

proc KillSrmRequest {requestId} {

    global State SrmRequestTimer
    upvar #0 SrmRequest$requestId request

    if {[dict exists $SrmRequestTimer $requestId]} {
        dict unset SrmRequestTimer $requestId
    }

    set requestType [dict get $request requestType]

    if {[info exists request]} {
        foreach fileId [dict get $request fileIds] {
            upvar #0 SrmFile$fileId file

            if {[string equal $requestType copy]} {
                SrmCallStop $fileId
                GridFtpStop $fileId
            }

            if {[info exists file]} {
                unset file
            }
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

    log::log notice $line

    set state [lindex $line 0]
    set requestType [lindex $line 1]
    set uniqueId [lindex $line 2]
    set output [lindex $line 3]

    switch -glob -- $state,$requestType {
        Failed,getUserName {
            SrmUserNameFailed $uniqueId $output
        }
        Failed,* {
            SrmFailed $uniqueId $output
        }
        Ready,getUserName {
            SrmUserNameReady $uniqueId $output
        }
        Ready,get {
            set permMode [string map $PermDict [lindex $output 0]]
            set stat [lreplace $output 0 1 $permMode]
            SrmReadyToGet $uniqueId $stat false
        }
        Ready,put {
            SrmReadyToPut $uniqueId false
        }
        Ready,advisoryDelete {
            SrmDeleteDone $uniqueId
        }
    }
}

# -------------------------------------------------------------------------

package provide srmlite::frontend 0.1


