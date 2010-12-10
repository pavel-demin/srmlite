package require dict
package require tdom
package require log

package require srmlite::templates
package require srmlite::notifier
package require srmlite::http
package require srmlite::soap

package require XOTcl

namespace eval ::srmlite::srmv2::client {
    namespace import ::xotcl::*
    namespace import ::srmlite::http::*
    namespace import ::srmlite::notifier::*

# -------------------------------------------------------------------------

    variable resp
    array set resp {
        get       {TCP_ERROR retry SRM_FAILURE failure SRM_INVALID_PATH failure SRM_REQUEST_QUEUED token SRM_REQUEST_INPROGRESS token SRM_SUCCESS transfer}
        put       {TCP_ERROR retry SRM_FAILURE failure SRM_REQUEST_QUEUED token SRM_SUCCESS token}
        token     {SRM_FAILURE failure SRM_SUCCESS status}
        status    {TCP_ERROR retry SRM_FAILURE failure SRM_INVALID_PATH failure SRM_REQUEST_QUEUED status SRM_REQUEST_INPROGRESS status SRM_SUCCESS transfer}
        getDone   {TCP_ERROR retry SRM_FAILURE success SRM_SUCCESS success}
        putDone   {TCP_ERROR retry SRM_FAILURE success SRM_SUCCESS success}
        abort     {TCP_ERROR retry SRM_FAILURE success SRM_SUCCESS success}
        done      {TCP_ERROR retry SRM_FAILURE success SRM_SUCCESS success}
    }

# -------------------------------------------------------------------------

    Class SrmClient -superclass Notifier -parameter {
        {certProxy}
        {serviceURL}
        {SURL}
        {size}
    }

# -------------------------------------------------------------------------

    SrmClient instproc log {level args} {
        my instvar serviceURL
        log::log $level "\[server $serviceURL\] [join $args { }]"
    }

# -------------------------------------------------------------------------

    SrmClient instproc init {} {
        my instvar certProxy serviceURL

        set certProxyOpts {}
        if {[my exists certProxy]} {
            set certProxyOpts "-certProxy $certProxy"
        }

        my set request [eval [list HttpRequest new -childof [self] \
            -timeout 60000 \
            -url $serviceURL \
            -agent Axis/1.3 \
            -accept {application/soap+xml, application/dime, multipart/related, text/*} \
            -type {text/xml; charset=utf-8} \
            -callbackRecipient [self]] \
            $certProxyOpts]
        next
    }

# -------------------------------------------------------------------------

    SrmClient instproc get {} {
        my instvar request requestType statusType SURL

        my set state get

	set statusType srmStatusOfGetRequest
        set requestType srmPrepareToGet
        $request send \
           -query [srmPrepareToGetReqBody $SURL] \
           -headers [srmHeaders $requestType]

    }

# -------------------------------------------------------------------------

    SrmClient instproc put {} {
        my instvar request requestType statusType SURL size

        my set state put

	set statusType srmStatusOfPutRequest
        set requestType srmPrepareToPut
        $request send \
           -query [srmPrepareToPutReqBody $SURL $size] \
           -headers [srmHeaders $requestType]

    }

# -------------------------------------------------------------------------

    SrmClient instproc token {} {
        my instvar result

        my set state token

        if {[dict exists $result requestToken]} {
            my set requestToken [dict get $result requestToken]
            my updateState SRM_SUCCESS
        } else {
            my set faultString {Request token is not available}
            my updateState SRM_FAILURE
        }
    }

# -------------------------------------------------------------------------

    SrmClient instproc getFromFileStatus {key} {
        my instvar result

        set arrayOfFileStatuses [dict get $result arrayOfFileStatuses]
        set fileStatus [lindex $arrayOfFileStatuses 0]
        return [dict get $fileStatus $key]
    }

# -------------------------------------------------------------------------

    SrmClient instproc sendRequest {type} {
        my instvar request requestToken SURL

        if {![my exists requestToken]} {
            my set faultString {Request token is not available}
            my updateState SRM_FAILURE
            return
        }

        my set requestType $type

        $request send \
           -query [${type}ReqBody $requestToken $SURL] \
           -headers [srmHeaders $type]
    }

# -------------------------------------------------------------------------

    SrmClient instproc status {} {
        my set state status

#        set estimatedWaitTime [my getFromFileStatus estimatedWaitTime]
#        set estimatedWaitTime [expr $estimatedWaitTime * 800]
        set estimatedWaitTime 10

        set afterId [after $estimatedWaitTime [myproc sendRequest [my set statusType]]]
    }

# -------------------------------------------------------------------------

    SrmClient instproc getDone {} {
        my set state getDone
        my sendRequest srmReleaseFiles
    }

# -------------------------------------------------------------------------

    SrmClient instproc putDone {} {
        my set state putDone
        my sendRequest srmPutDone
    }

# -------------------------------------------------------------------------

    SrmClient instproc abort {} {
        my set state abort
        my sendRequest srmAbortFiles
    }

# -------------------------------------------------------------------------

    SrmClient instproc transfer {} {
        my set state transfer
        my notify successCallback [my getFromFileStatus transferURL]
    }

# -------------------------------------------------------------------------

    SrmClient instproc retry {} {
        my instvar state afterId retryCounter

        if {[my exists retryCounter($state)]} {
            incr retryCounter($state)
        } else {
            set retryCounter($state) 0
        }

        if {$retryCounter($state) >= 3} {
            my set faultString "Failed to $state"
            my updateState SRM_FAILURE
            return
        }

        set afterId [after 10000 [myproc $state]]
    }

# -------------------------------------------------------------------------

    SrmClient instproc cancel {} {
        my instvar request afterId
        if {[my exists afterId]} {
            after cancel $afterId
        }
        $request done
    }

# -------------------------------------------------------------------------

    SrmClient instproc success {} {
        my set state success
        my notify successCallback finished
    }

# -------------------------------------------------------------------------

    SrmClient instproc failure {} {
        my set state failure
        my notify failureCallback [my set faultString]
    }

# -------------------------------------------------------------------------

    SrmClient instproc successCallback {content} {
        my process $content
    }

# -------------------------------------------------------------------------

    SrmClient instproc failureCallback {reason} {
        my log error "Error while connecting to remote SRM: $reason"
        my updateState TCP_ERROR
    }

# -------------------------------------------------------------------------

    SrmClient instproc process {content} {
        my instvar result

        if {[catch {dom parse $content} document]} {
            my log error $document
            my set faultString "Error while parsing SOAP XML from remote SRM"
            my updateState SRM_FAILURE
            return
        }

        set root [$document documentElement]

        set ns {soap http://schemas.xmlsoap.org/soap/envelope/}

        set methodNode [$root selectNodes -namespaces $ns {/soap:Envelope/soap:Body/*[1]}]
        set methodName [$methodNode localName]

        if {![string equal $methodName [my set requestType]Response]} {
            $document delete
            my set faultString "Unknown SOAP response from remote SRM: $methodName"
            my updateState SRM_FAILURE
            return
        }

        set methodDict [SoapDecompose $methodNode]

        $document delete

        set result [dict get $methodDict $methodName]

        if {[dict exists $result returnStatus explanation] &&
            [dict exists $result returnStatus statusCode]} {
            my set faultString [dict get $result returnStatus explanation]
            my updateState [dict get $result returnStatus statusCode]
        } else {
            my set faultString {Request status is not available}
            my updateState SRM_FAILURE
        }
    }

# -------------------------------------------------------------------------

    SrmClient instproc updateState {code} {
        my instvar state
        variable resp

        foreach {retCode newState} $resp($state) {
            if {[string equal $retCode $code]} {
	        if {[catch {my $newState} result]} {
                    my set faultString $result
                    my failure
	        }
    	        return
            }
        }

        my set faultString "Unknown state $state,$code"
        my failure
    }

# -------------------------------------------------------------------------

   namespace export SrmClient

}

package provide srmlite::srmv2::client 0.1
