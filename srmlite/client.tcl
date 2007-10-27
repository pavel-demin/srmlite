package require g2lite
package require gtlite
package require dict
package require tdom
package require http

package require srmlite::templates
package require srmlite::soap

# -------------------------------------------------------------------------

proc SrmCall {fileId serviceURL requestType args} {

    upvar #0 SrmFiles($fileId) file
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

    set ::env(X509_USER_PROXY) $certProxy

    ::http::geturl $serviceURL \
        -query $query \
        -type {text/xml; charset=utf-8} \
        -headers [SrmHeaders $requestType] \
        -command [list SrmCallCommand $fileId $requestType]

}

# -------------------------------------------------------------------------

proc SrmCallCommand {fileId responseType token} {

    global errorInfo

    if {[catch {SrmCallDone $fileId $responseType $token} result]} {
         log::log error $result
    }
}

# -------------------------------------------------------------------------

proc SrmCallDone {fileId responseType token} {

    upvar #0 $token http
    upvar #0 SrmClients($fileId) client

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
    }

    # Extract the parameters.
    set argValues {}
    foreach arg [$methodNode childNodes] {
        lappend argValues [SoapDecompose $arg]
    }

    $document delete

    set result [eval dict create [lindex $argValues 0]]

    dict with result {

        set remoteRequestId $requestId
        set remoteRequestType [string tolower $type]
        set remoteErrorMessage $errorMessage
        set remoteRetryDeltaTime $retryDeltaTime

        set remoteFile [eval dict create [lindex $fileStatuses 0]]

        set remoteFileState [dict get $remoteFile state]
        set remoteFileId [dict get $remoteFile fileId]
    }

    if {![string equal $responseType getRequestStatus] &&
        ![string equal $responseType setFileStatus]} {
        set client [dict create afterId {} serviceURL $serviceURL \
            remoteRequestId $remoteRequestId remoteFileId $remoteFileId \
            remoteFileState Pending]
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
            SrmFailed $fileId "Request to remote SRM failed: $remoteErrorMessage"
        }
    }
}

# -------------------------------------------------------------------------

proc SrmCallStop {fileId} {

    upvar #0 SrmFiles($fileId) file
    set certProxy [dict get $file certProxy]

    log::log debug "SrmCallStop: $fileId"

    upvar #0 SrmClients($fileId) client

    if {![info exists client]} {
        log::log warning "SrmCallStop: Unknown file id $fileId"
        return
    }

    dict with client {
        if {![string equal $afterId {}]} {
            after cancel $afterId
        }
        set query [SrmSetFileStatusBody $remoteRequestId $remoteFileId Done]
    }

    set ::env(X509_USER_PROXY) $certProxy

    ::http::geturl $serviceURL \
        -query $query \
        -type {text/xml; charset=utf-8} \
        -headers [SrmHeaders setFileStatus] \
        -command [list SrmCallStopCommand $fileId $certProxy]

}

# -------------------------------------------------------------------------

proc SrmCallStopCommand {fileId certProxy token} {

    upvar #0 $token http
    ::http::cleanup $token

    upvar #0 SrmClients($fileId) client
    if {[info exists client]} {
        unset client
    }
    
    if {[file exists $certProxy]} {
        file delete $certProxy
    }
}

# -------------------------------------------------------------------------

proc ::gss::socket {args} {

    set hadError 0

    if {[catch {eval ::socket $args} result]} {
        set hadError 1
        log::log error $result
    } elseif {[catch {gss::import $result -server false} result]} {
        set hadError 1
        log::log error $result
    }

    if {[info exists ::env(X509_USER_PROXY)]} {
        unset ::env(X509_USER_PROXY)
    }

    if {$hadError} {
        return -code error $result
    } else {
        return $result
    }
}

# -------------------------------------------------------------------------

::http::register srm 8443 ::gss::socket

::http::config -useragent Axis/1.3 -accept {application/soap+xml, application/dime, multipart/related, text/*}

# -------------------------------------------------------------------------

package provide srmlite::client 0.1
