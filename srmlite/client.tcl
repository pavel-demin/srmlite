package require g2lite
package require gtlite
package require dict
package require tdom
package require http

package require srmlite::templates
package require srmlite::soap

# -------------------------------------------------------------------------

proc SrmCall {fileId certProxy serviceURL requestType args} {

    log::log debug "SrmCall $fileId $serviceURL $requestType $args"

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
        -command [list SrmCallCommand $fileId $certProxy]

}

# -------------------------------------------------------------------------

proc SrmCallCommand {fileId certProxy token} {

    global errorInfo

    if {[catch {SrmCallDone $fileId $certProxy $token} result]} {
         log::log error $result
    }
}
# -------------------------------------------------------------------------

proc SrmCallDone {fileId certProxy token} {

    upvar #0 $token http
    upvar #0 SrmFiles($fileId) file

    log::log debug "SrmCallDone $fileId"

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

    if {![info exists request]} {
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

    # Extract the parameters.
    set argValues {}
    foreach arg [$methodNode childNodes] {
        lappend argValues [SoapDecompose $arg]
    }

    $document delete

    array set result [lindex $argValues 0]

    set remoteRequestId $result(requestId)
    set remoteRequestType [string tolower $result(type)]
    set remoteState $result(state)
    set retryDeltaTime $result(retryDeltaTime)

    array set fileStatus [lindex $result(fileStatuses) 0]

    set localFileState [dict get file state]
    set remoteFileState $fileStatus(state)
    set remoteFileId $fileStatus(fileId)

    log::log debug "SrmCallDone $fileId $remoteRequestId $remoteFileId $localFileState,$remoteFileState"

    switch -glob -- $localFileState,$remoteFileState {
        *,Ready {
            # set state to Running
            log::log debug "SrmCallDone $fileId setFileStatus $remoteRequestId $remoteFileId Running"
            set call [list SrmCall $fileId $certProxy $serviceURL setFileStatus $remoteRequestId $remoteFileId Running]
            dict set file afterId [after [expr $retryDeltaTime * 800] $call]
            switch -- $remoteRequestType {
                get {
                    set stat [list $fileStatus(permMode) \
                                   $fileStatus(owner) \
                                   $fileStatus(group) \
                                   $fileStatus(size)]
                    SrmReadyToGet $fileId $stat true $fileStatus(TURL)
                }
                put {
                    SrmReadyToPut $fileId true $fileStatus(TURL)
                }
            }
        }
        *,Done {
            log::log debug "SrmCallDone $remoteRequestId $remoteFileId is Done"
        }
        *,Failed {
            SrmFailed $fileId "Request to remote SRM failed: $result(errorMessage)"
        }
        Failed,* -
        Done,* {
            # set state to Done
            log::log debug "SrmCallDone $fileId setFileStatus $remoteRequestId $remoteFileId Done"
            set call [list SrmCall $fileId $certProxy $serviceURL setFileStatus $remoteRequestId $remoteFileId Done]
            dict set file afterId [after 0 $call]
        }
        default {
            set call [list SrmCall $fileId $certProxy $serviceURL getRequestStatus $remoteRequestId]
            dict set file afterId [after [expr $retryDeltaTime * 800] $call]
        }
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
