
package require gss::socket
package require g2lite
package require dict
package require tdom

package require srmlite::gridhttp
package require srmlite::templates
package require srmlite::soap

# -------------------------------------------------------------------------

proc SrmCall {fileId serviceURL requestType args} {

    upvar #0 SrmFile$fileId file
    upvar #0 SrmClient$fileId client

    set certProxy [dict get $file certProxy]

    log::log debug "SrmCall: $fileId $serviceURL $requestType $args"

    switch -- $requestType {
        get {
            set query [eval SrmGetBody $args]
        }
        put {
            set query [eval SrmPutBody $args]
        }
        copy {
            set query [eval SrmCopyBody $args]
        }
        getRequestStatus {
            set query [eval SrmGetRequestStatusBody $args]
        }
        setFileStatus {
            set query [eval SrmSetFileStatusBody $args]
        }
    }

    if {![string equal $requestType getRequestStatus] &&
        ![string equal $requestType setFileStatus]} {
        set client [dict create afterId {} serviceURL $serviceURL \
            remoteRequestId {} remoteFileId {} \
            remoteFileState Pending]
    }

    set type {text/xml; charset=utf-8}
    set headers [SrmHeaders $requestType]
    set command [list SrmCallCommand $fileId $requestType]

    if {[catch {::http::geturl $serviceURL -query $query \
        -timeout 30000 -gssimport $certProxy \
        -type $type -headers $headers -command $command} result]} {
        log::log error "SrmCall: $result"
        SrmFailed $fileId "Error while connecting remote SRM: $result"
    }
}

# -------------------------------------------------------------------------

proc SrmCallCommand {fileId responseType token} {

    global errorInfo

    if {[catch {SrmCallDone $fileId $responseType $token} result]} {
         log::log error "SrmCallCommand: $result"
    }
}

# -------------------------------------------------------------------------

proc SrmCallDone {fileId responseType token} {

    upvar #0 $token http
    upvar #0 SrmClient$fileId client

    log::log debug "SrmCallDone: $fileId"

    set serviceURL $http(url)
    set content [::http::data $token]
    set status [::http::status $token]
    set ncode [::http::ncode $token]

    set hadError 0
    if {![string equal $status ok] ||
        ($ncode != 200 && [string equal $content {}])} {
        set hadError 1
        set faultString [::http::error $token]
    }

    ::http::cleanup $token

    if {$hadError} {
        log::log error "SrmCallDone: \[code $ncode\] \[status $status\]"
        SrmFailed $fileId "Error while connecting remote SRM: $faultString"
        return
    }

    if {[catch {dom parse $content} document]} {
        log::log error $document
        SrmFailed $fileId "Error while parsing SOAP XML from remote SRM"
        return
    }

    set root [$document documentElement]

    set ns {soap http://schemas.xmlsoap.org/soap/envelope/}

    set methodNode [$root selectNodes -namespaces $ns {/soap:Envelope/soap:Body/*[1]}]
    set methodName [$methodNode localName]

    if {![string equal $methodName ${responseType}Response]} {
        $document delete
        set faultString "Unknown SOAP response from remote SRM: $methodName"
        log::log error $faultString
        SrmFailed $fileId $faultString
        return
    }

    set methodDict [SoapDecompose $methodNode]

    $document delete

    set result [dict get $methodDict Result]

    set remoteRequestId [dict get $result requestId]
    set remoteRequestType [string tolower [dict get $result type]]
    set remoteRetryDeltaTime [dict get $result retryDeltaTime]

    set remoteFileStatuses [dict get $result fileStatuses]
    set remoteFile [lindex $remoteFileStatuses 0]

    set remoteFileState [dict get $remoteFile state]
    set remoteFileId [dict get $remoteFile fileId]

    if {![string equal $responseType getRequestStatus] &&
        ![string equal $responseType setFileStatus]} {
        dict set client remoteRequestId $remoteRequestId
        dict set client remoteFileId $remoteFileId
    }

    log::log debug "SrmCallDone: $fileId $remoteRequestId $remoteFileId $remoteFileState"

    switch -- $remoteFileState {
        Pending {
            set call [list SrmCall $fileId $serviceURL getRequestStatus $remoteRequestId]
            dict set client afterId [after [expr $remoteRetryDeltaTime * 800] $call]
        }
        Ready {
            # set state to Running
            dict set client remoteFileState Running
            log::log debug "SrmCallDone: $fileId setFileStatus $remoteRequestId $remoteFileId Running"
            set call [list SrmCall $fileId $serviceURL setFileStatus $remoteRequestId $remoteFileId Running]
            dict set client afterId [after [expr $remoteRetryDeltaTime * 800] $call]

            switch -- $remoteRequestType {
                get {
                    set stat [list [dict get $remoteFile permMode] \
                                   [dict get $remoteFile owner] \
                                   [dict get $remoteFile group] \
                                   [dict get $remoteFile size]]
                    SrmReadyToGet $fileId $stat true [dict get $remoteFile TURL]
                }
                put {
                    SrmReadyToPut $fileId true [dict get $remoteFile TURL]
                }
            }
        }
        Done {
            log::log debug "SrmCallDone: $remoteRequestId $remoteFileId is Done"
        }
        Failed {
            set remoteErrorMessage [dict get $result errorMessage]
            SrmFailed $fileId "Request to remote SRM failed: $remoteErrorMessage"
        }
    }
}

# -------------------------------------------------------------------------

proc SrmCallStop {fileId} {

    upvar #0 SrmFile$fileId file

    set afterId [dict get $file afterId]

    log::log debug "SrmCallStop: $fileId $afterId"

    if {![string equal $afterId {}]} {
        after cancel $afterId
    }

    upvar #0 SrmClient$fileId client

    if {![info exists client]} {
        log::log warning "SrmCallStop: Unknown file id $fileId"
        return
    }

    set afterId [dict get $client afterId]

    if {![string equal $afterId {}]} {
        after cancel $afterId
    }

    set certProxy [dict get $file certProxy]

    set serviceURL [dict get $client serviceURL]
    set remoteRequestId [dict get $client remoteRequestId]
    set remoteFileId [dict get $client remoteFileId]

    if {![string equal $remoteRequestId {}] &&
        ![string equal $remoteFileId {}]} {

        set query [SrmSetFileStatusBody $remoteRequestId $remoteFileId Done]

        set type {text/xml; charset=utf-8}
        set headers [SrmHeaders setFileStatus]
        set command [list SrmCallStopCommand $fileId]

        if {[catch {::http::geturl $serviceURL -query $query \
            -timeout 30000 -gssimport $certProxy \
            -type $type -headers $headers -command $command} result]} {
            log::log error "SrmCallStop: $result"
            SrmFailed $fileId "Error while connecting remote SRM: $result"
        }
    } else {
        SrmCallStopCommand $fileId {}
    }

}

# -------------------------------------------------------------------------

proc SrmCallStopCommand {fileId token} {

    if {![string equal $token {}]} {
        ::http::cleanup $token
    }

    log::log debug "SrmCallStopCommand: $fileId"

    upvar #0 SrmClient$fileId client

    if {[info exists client]} {
        unset client
    }

    upvar #0 SrmFile$fileId file

    if {[info exists file]} {
        set certProxy [dict get $file certProxy]
        if {![string equal $certProxy {}]} {
            log::log debug "SrmCallStopCommand: $certProxy destroy"
            $certProxy destroy
            dict set file certProxy {}
        }
    }
}

# -------------------------------------------------------------------------

proc ::gss::socket {args} {

    if {[catch {eval ::socket $args} result]} {
        log::log error $result
        return -code error $result
    }
    return $result
}

# -------------------------------------------------------------------------

::http::register srm 8443 ::gss::socket

::http::config -useragent Axis/1.3 -accept {application/soap+xml, application/dime, multipart/related, text/*}

# -------------------------------------------------------------------------

package provide srmlite::client 0.1
