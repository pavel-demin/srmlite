package require tdom

package require srmlite::utilities
package require srmlite::templates
package require srmlite::notifier
package require srmlite::gridftp
package require srmlite::soap

package require srmlite::srmv2::client

package require XOTcl

namespace eval ::srmlite::srmv2::server {
    namespace import ::xotcl::*
    namespace import ::srmlite::gridftp::*
    namespace import ::srmlite::notifier::*
    namespace import ::srmlite::utilities::*
    namespace import ::srmlite::srmv2::client::*

# -------------------------------------------------------------------------

    variable methods
    array set methods {
        srmPing srmPing
        srmLs srmLs
        srmCopy srmCopy
        srmRm srmRm
        srmMkdir srmMkdir
        srmPrepareToGet srmPrepareToGet
        srmPrepareToPut srmPrepareToPut
        srmStatusOfCopyRequest srmStatusOfCopyRequest
        srmStatusOfGetRequest srmStatusOfGetRequest
        srmStatusOfPutRequest srmStatusOfPutRequest
        srmReleaseFiles srmReleaseFiles
        srmPutDone srmPutDone
        srmAbortFiles srmAbortFiles
    }

# -------------------------------------------------------------------------

    Class Srmv2Manager -parameter {
       {frontendService}
       {cleanupService}
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc init {} {
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc process {connection input} {
        global errorInfo
        variable methods

        if {[$connection exists mime(soapaction)]} {
            set action [$connection set mime(soapaction)]
        } else {
            $connection error 411 {Confusing mime headers}
            return
        }

        if {[catch {dom parse $input} document]} {
           $connection log error $document
           $connection respond [srmFaultBody $document $errorInfo]
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

        $connection log notice {SOAP call} $methodName $methodDict

        if {[info exists methods($methodName)]} {
            if {[catch {dict get $methodDict ${methodName}Request} argValues]} {
                $connection log error $argValues
                $connection respond [srmFaultBody $argValues $errorInfo]
                return
            }

            if {[catch {my $methods($methodName) $connection $argValues} result]} {
                $connection log error $result
                $connection respond [srmFaultBody $result $errorInfo]
                return
            }
        } else {
            set faultString "Unknown SOAP call $methodName"
            $connection log error $faultString
            $connection respond [srmFaultBody $faultString $faultString]
            return
        }
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc createRequest {connection requestType isSync SURLS {dstSURLS {}} {sizes {}} {certProxies {}}} {

        set requestId [NewUniqueId]
        set requestObj [self]::${requestId}

        if {[my exists cleanupService]} {
            [my cleanupService] addObject $requestObj
        }

        set startClock [clock seconds]

        SrmRequest $requestObj \
	    -requestState SRM_REQUEST_QUEUED \
	    -isSyncRequest $isSync \
            -queueSize 0 \
            -requestType $requestType \
            -requestToken $requestId \
            -connection $connection

        set userName [$connection set userName]

        foreach SURL $SURLS dstSURL $dstSURLS size $sizes certProxy $certProxies {

            set fileId [NewUniqueId]
            set fileObj ${requestObj}::${fileId}

            if {$size == {}} {
                set size 0
            }

            SrmFile $fileObj \
                -callbackRecipient $requestObj \
                -frontendService [my frontendService] \
                -fileState SRM_REQUEST_QUEUED \
                -startClock $startClock \
                -fileSize $size \
                -SURL $SURL \
                -dstSURL $dstSURL \
                -userName $userName \
                -certProxy $certProxy

            $requestObj incr queueSize

            $fileObj $requestType
        }

        if {! $isSync} {
            $connection respond [${requestType}ResBody $requestObj]
        }
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmPing {connection argValues} {
        $connection respond [srmPingResBody]
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmLs {connection argValues} {
        my createRequest $connection srmLs 1 [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmRm {connection argValues} {
        my createRequest $connection srmRm 1 [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmMkdir {connection argValues} {
        my createRequest $connection srmMkdir 1 [dict get $argValues SURL]
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmPrepareToGet {connection argValues} {
        set SURLS [list]
        foreach request [dict get $argValues arrayOfFileRequests] {
            lappend SURLS [dict get $request sourceSURL]
        }
        my createRequest $connection srmPrepareToGet 0 $SURLS
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmPrepareToPut {connection argValues} {
        set SURLS [list]
        set sizes [list]
        foreach request [dict get $argValues arrayOfFileRequests] {
            lappend SURLS [dict get $request targetSURL]
            lappend sizes [dict get $request expectedFileSize]
        }
        my createRequest $connection srmPrepareToPut 0 $SURLS $SURLS $sizes
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmStatusOfCopyRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]

        if {[dict exists $argValues arrayOfSourceSURLs]} {
            my sendStatus $connection $requestToken srmStatusOfCopyRequest \
               [dict get $argValues arrayOfSourceSURLs]
        } else {
            my sendStatus $connection $requestToken srmStatusOfCopyRequest {}
        }
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmStatusOfGetRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]

        if {[dict exists $argValues arrayOfSourceSURLs]} {
            my sendStatus $connection $requestToken srmStatusOfGetRequest \
               [dict get $argValues arrayOfSourceSURLs]
        } else {
            my sendStatus $connection $requestToken srmStatusOfGetRequest {}
        }
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmStatusOfPutRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]

        if {[dict exists $argValues arrayOfTargetSURLs]} {
            my sendStatus $connection $requestToken srmStatusOfPutRequest \
               [dict get $argValues arrayOfTargetSURLs]
        } else {
            my sendStatus $connection $requestToken srmStatusOfPutRequest {}
        }
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmReleaseFiles {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmReleaseFiles \
	    Done [dict get $argValues arrayOfSURLs]
    }


# -------------------------------------------------------------------------

    Srmv2Manager instproc srmPutDone {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmPutDone \
	    Done [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmAbortFiles {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmAbortFiles \
	    Canceled [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc srmCopy {connection argValues} {
        global errorInfo

        set chan [$connection set chan]

        set srcSURLS [list]
        set dstSURLS [list]
        set certProxies [list]

        foreach request [dict get $argValues arrayOfFileRequests] {
            lappend srcSURLS [dict get $request sourceSURL]
            lappend dstSURLS [dict get $request targetSURL]
            if {[catch {fconfigure $chan -gssexport} result]} {
                $connection log error $result
                foreach proxy $certProxies {
                    $proxy destroy
                }
                $connection respond [srmFaultBody $result $errorInfo]
                return
            } else {
                $connection log debug "new certProxy $result"
                lappend certProxies $result
            }
        }

        my createRequest $connection srmCopy 0 $srcSURLS $dstSURLS {} $certProxies
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc sendStatus {connection requestToken requestType SURLS} {

        set requestObj [self]::${requestToken}
        if {! [Object isobject $requestObj]} {
            $connection respond [srmStatusResBody $requestType SRM_INVALID_REQUEST {Unknown request token}]
            return
        }

        set currentClock [clock seconds]

        if {[llength $SURLS] == 0} {
            set files [$requestObj info children]

            foreach fileObj $files {
                set counter [$fileObj incr counter]
                $fileObj set waitTime [expr {$counter / 4 * 5 + 1}]

                set startClock [$fileObj startClock]
                if {[$fileObj fileTime] > 0} {
                    $fileObj incr fileTime [expr {$startClock - $currentClock}]
                    if {[$fileObj fileTime] <= 0} {
                        $fileObj set fileTime 0
                        $fileObj set fileState SRM_FILE_LIFETIME_EXPIRED
                    }
                }
            }
            $connection respond [${requestType}ResBody $requestObj $files]
            return
        }

        set requestId [NewUniqueId]
        set requestTmp [self]::${requestId}

        SrmRequest $requestTmp \
	    -requestState [$requestObj requestState] \
            -requestType $requestType \
            -requestToken $requestId

        set files [list]
        foreach SURL $SURLS {
            if {[$requestObj existsFile $SURL]} {
                set fileObj [$requestObj getFile $SURL]

                set counter [$fileObj incr counter]
                $fileObj set waitTime [expr {$counter / 4 * 5 + 1}]

                set startClock [$fileObj startClock]
                if {[$fileObj fileTime] > 0} {
                    $fileObj incr fileTime [expr {$startClock - $currentClock}]
                    if {[$fileObj fileTime] <= 0} {
                        $fileObj set fileTime 0
                        $fileObj set fileState SRM_FILE_LIFETIME_EXPIRED
                    }
                }

                lappend files $fileObj
            } else {
                set fileId [NewUniqueId]
                set fileTmp ${requestTmp}::${fileId}
                SrmFile $fileTmp \
                    -fileState SRM_INVALID_PATH \
                    -SURL $SURL
                lappend files $fileTmp
            }
        }
        $connection respond [${requestType}ResBody $requestTmp $files]
        $requestTmp destroy
    }

# -------------------------------------------------------------------------

    Srmv2Manager instproc releaseFiles {connection requestToken requestType explanation SURLS} {

        set requestObj [self]::${requestToken}
        if {! [Object isobject $requestObj]} {
            $connection respond [srmStatusResBody SRM_INVALID_REQUEST {Unknown request token}]
            return
        }

        if {[llength $SURLS] == 0} {
            set files [$requestObj info children]

            foreach fileObj $files {
                $fileObj set fileState SRM_SUCCESS
                $fileObj set fileStateComment $explanation
                $fileObj abort
            }
            $connection respond [${requestType}ResBody $requestObj $files]
            return
        }

        set requestId [NewUniqueId]
        set requestTmp [self]::${requestId}

        set currentClock [clock seconds]

        SrmRequest $requestTmp \
	    -requestState [$requestObj requestState] \
            -requestType $requestType \
            -requestToken $requestId

        set files [list]
        foreach SURL $SURLS {
	    if {[$requestObj existsFile $SURL]} {
                set fileObj [$requestObj getFile $SURL]

                $fileObj set fileState SRM_SUCCESS
                $fileObj set fileStateComment $explanation
                $fileObj abort

                lappend files $fileObj
	    } else {
                set fileId [NewUniqueId]
                set fileTmp ${requestTmp}::${fileId}
                SrmFile $fileTmp \
                    -fileState SRM_INVALID_PATH \
                    -SURL $SURL
                lappend files $fileTmp
            }
        }
        $connection respond [${requestType}ResBody $requestTmp $files]
        $requestTmp destroy
    }

# -------------------------------------------------------------------------

    Class SrmRequest -superclass Notifier -parameter {
        {requestState SRM_REQUEST_QUEUED}
        {isSyncRequest 0}
        {queueSize 0}
        {requestType}
        {requestToken}
        {connection}
    }

# -------------------------------------------------------------------------

    SrmRequest instproc init {} {
      my set successFlag 0
      my set failureFlag 0
      my set fileDict [dict create]
      next
    }

# -------------------------------------------------------------------------

    SrmRequest instproc setFile {SURL obj} {
        my instvar fileDict
        dict set fileDict $SURL $obj
    }

# -------------------------------------------------------------------------

    SrmRequest instproc getFile {SURL} {
        my instvar fileDict
        dict get $fileDict $SURL
    }

# -------------------------------------------------------------------------

    SrmRequest instproc existsFile {SURL} {
        my instvar fileDict
        dict exists $fileDict $SURL
    }

# -------------------------------------------------------------------------

    SrmRequest instproc updateState {} {
        my instvar successFlag failureFlag connection
        if {[my queueSize] > 0} {
            my set requestState SRM_REQUEST_INPROGRESS
            return
        }

        if {$successFlag && ! $failureFlag} {
            my set requestState SRM_SUCCESS
        } elseif {! $successFlag && $failureFlag} {
            my set requestState SRM_FAILURE
        } else {
            my set requestState SRM_PARTIAL_SUCCESS
        }

        if {[my isSyncRequest]} {
            if {[Object isobject $connection]} {
                $connection respond [[my requestType]ResBody [self]]
            }
            my destroy
        }
    }

# -------------------------------------------------------------------------

    SrmRequest instproc successCallback {result} {
        my set successFlag 1
        my incr queueSize -1
        my updateState
    }

# -------------------------------------------------------------------------

    SrmRequest instproc failureCallback {reason} {
        my set failureFlag 1
        my incr queueSize -1
        my updateState
    }
# -------------------------------------------------------------------------

    variable resp
    array set resp {
        ls        {Ready success Failed failure}
        rm        {Ready success Failed failure}
        mkdir     {Ready success Failed failure}
        get       {Ready success Failed failure}
        put       {Ready success Failed failure}
        copyPull  {Ready remoteGet Failed failure}
        copyPush  {Ready remotePut Failed failure}
        remoteGet {Ready pull Failed failure}
        remotePut {Ready push Failed failure}
        pull      {Ready getDone Failed abort}
        push      {Ready putDone Failed abort}
        getDone   {Ready success}
        putDone   {Ready success}
        abort     {Ready success}
        failure   {Failed failure}
    }

# -------------------------------------------------------------------------

    Class SrmFile -superclass Notifier -parameter {
        {fileState SRM_REQUEST_QUEUED}
        {startClock}
        {waitTime 1}
        {counter 1}
        {fileTime 7200}
        {fileSize 0}
        {SURL}
        {dstSURL}
        {TURL}
        {userName}
        {certProxy}
        {frontendService}
    }

# -------------------------------------------------------------------------

    SrmFile instproc updateState {code} {
        my instvar state faultString
        variable resp

        foreach {retCode newState} $resp($state) {
            if {[string equal $retCode $code]} {
	        my $newState
    	        return
            }
        }

        set faultString "Unknown state $state,$code"
        my failure
    }

# -------------------------------------------------------------------------

    SrmFile instproc failure {} {
        my notify failureCallback {}
    }

# -------------------------------------------------------------------------

    SrmFile instproc success {} {
        my instvar client transfer
        if {[my exists transfer]} {
            $transfer destroy
            unset transfer
        }
        if {[my exists client]} {
            $client destroy
            unset client
        }
        my notify successCallback {}
    }

# -------------------------------------------------------------------------

    SrmFile instproc remoteGet {} {
        my instvar client certProxy SURL

        my set fileState SRM_REQUEST_INPROGRESS
        my set state remoteGet

	regexp {[^?]*} $SURL serviceURL
        if {[catch {SrmClient new \
            -childof [self] \
            -certProxy $certProxy \
            -serviceURL $serviceURL \
            -SURL $SURL \
            -callbackRecipient [self]} client]} {
            my set fileState SRM_FAILURE
            my set fileStateComment $client
            my updateState Failed
        }

        $client get
    }

# -------------------------------------------------------------------------

    SrmFile instproc remotePut {} {
        my instvar client certProxy dstSURL

        my set fileState SRM_REQUEST_INPROGRESS
        my set state remotePut

        regexp {[^?]*} $dstSURL serviceURL
        if {[catch {SrmClient new \
            -childof [self] \
            -certProxy $certProxy \
            -serviceURL $serviceURL \
            -SURL $dstSURL \
            -callbackRecipient [self]} client]} {
            my set fileState SRM_FAILURE
            my set fileStateComment $client
            my updateState Failed
        }

        $client put
    }

# -------------------------------------------------------------------------

    SrmFile instproc pull {} {
        my instvar transfer certProxy TURL result

        my set state pull

        set transfer [GridFtpTransfer new \
            -childof [self] \
            -certProxy $certProxy \
            -srcTURL $result \
            -dstTURL $TURL \
            -callbackRecipient [self]]

       $transfer start
    }

# -------------------------------------------------------------------------

    SrmFile instproc push {} {
        my instvar transfer certProxy TURL result

        my set state push

        set transfer [GridFtpTransfer new \
            -childof [self] \
            -certProxy $certProxy \
            -srcTURL $TURL \
            -dstTURL $result \
            -callbackRecipient [self]]

       $transfer start
    }

# -------------------------------------------------------------------------

    SrmFile instproc getDone {} {
        my instvar client

        my set fileState SRM_SUCCESS
        my set state getDone

        if {[my exists client]} {
            $client getDone
        }
    }

# -------------------------------------------------------------------------

    SrmFile instproc putDone {} {
        my instvar client

        my set fileState SRM_SUCCESS
        my set state putDone

        if {[my exists client]} {
            $client putDone
        }
    }

# -------------------------------------------------------------------------

    SrmFile instproc abort {} {
        my instvar client transfer

        my set state abort

        if {[my exists transfer]} {
            $transfer destroy
            unset transfer
        }

        if {[my exists client]} {
            $client abort
        }
    }

# -------------------------------------------------------------------------

    SrmFile instproc done {} {
        my instvar client transfer

        my set state done

        if {[my exists client]} {
            $client destroy
            unset client
        }

        if {[my exists transfer]} {
            $transfer destroy
            unset transfer
        }
    }

# -------------------------------------------------------------------------

    SrmFile instproc srmLs {} {
        my instvar userName SURL

        my set state ls
        [my frontendService] process [list ls [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    SrmFile instproc srmRm {} {
        my instvar userName SURL

        my set state rm
        [my frontendService] process [list rm [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    SrmFile instproc srmMkdir {} {
        my instvar userName SURL

        my set state mkdir
        [my frontendService] process [list mkdir [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    SrmFile instproc srmPrepareToGet {} {
        my instvar userName SURL

        my set state get
        [my info parent] setFile $SURL [self]
        [my frontendService] process [list get [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    SrmFile instproc srmPrepareToPut {} {
        my instvar userName dstSURL

        my set state put
        [my info parent] setFile $dstSURL [self]
        [my frontendService] process [list put [self] $userName $dstSURL]
    }

# -------------------------------------------------------------------------

    SrmFile instproc srmCopy {} {
        my instvar userName SURL dstSURL

        if {[IsLocalHost $SURL] && ![IsLocalHost $dstSURL]} {
            my set state copyPush
            [my info parent] setFile $SURL [self]
            [my frontendService] process [list get [self] $userName $SURL]
        } elseif {![IsLocalHost $SURL] && [IsLocalHost $dstSURL]} {
            my set state copyPull
            [my info parent] setFile $SURL [self]
            [my frontendService] process [list put [self] $userName $dstSURL]
        } else {
            my set state failure
            my set fileState SRM_NOT_SUPPORTED
            my set fileStateComment {copying between two local or two remote SURLs is not allowed}
            my updateState Failed
        }
    }

# -------------------------------------------------------------------------

    SrmFile instproc lsSuccess {result} {
        my set fileState SRM_SUCCESS
        my set metadata $result
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc lsFailure {reason} {
        my set fileState SRM_INVALID_PATH
        my set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    SrmFile instproc rmSuccess {result} {
        my set fileState SRM_SUCCESS
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc rmFailure {reason} {
        my set fileState SRM_FAILURE
        my set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    SrmFile instproc mkdirSuccess {result} {
        my set fileState SRM_SUCCESS
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc mkdirFailure {reason} {
        my set fileState SRM_FAILURE
        my set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    SrmFile instproc getSuccess {result} {
        my set fileState SRM_FILE_PINNED
        my set fileSize [lindex [lindex $result 0] 4]
        my set TURL [ConvertSURL2TURL [my set SURL]]
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc getFailure {reason} {
        my set fileState SRM_INVALID_PATH
        my set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    SrmFile instproc putSuccess {result} {
        my set fileState SRM_SPACE_AVAILABLE
        my set TURL [ConvertSURL2TURL [my set dstSURL]]
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc putFailure {reason} {
        my set fileState SRM_INVALID_PATH
        my set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    SrmFile instproc successCallback {result} {
        my set result $result
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc failureCallback {reason} {
        my set fileState SRM_FAILURE
        my set fileStateComment $reason
        my updateState Failed
    }

# -------------------------------------------------------------------------

    namespace export Srmv2Manager
}

package provide srmlite::srmv2::server 0.1
