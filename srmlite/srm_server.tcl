package require log
package require tdom
package require XOTcl

package require srmlite::utilities
package require srmlite::templates
package require srmlite::soap

namespace eval ::srmlite::srm::server {
    namespace import ::xotcl::*
    namespace import ::srmlite::utilities::*

# -------------------------------------------------------------------------

    variable methods
    array set methods {
        srmPing srmPing
        srmLs srmLs
        srmRm srmRm
        srmMkdir srmMkdir
        srmRmdir srmRmdir
        srmPrepareToGet srmPrepareToGet
        srmPrepareToPut srmPrepareToPut
        srmStatusOfGetRequest srmStatusOfGetRequest
        srmStatusOfPutRequest srmStatusOfPutRequest
        srmReleaseFiles srmReleaseFiles
        srmPutDone srmPutDone
        srmAbortFiles srmAbortFiles
        srmAbortRequest srmAbortRequest
    }

# -------------------------------------------------------------------------

    Class SrmManager -parameter {
       {frontendService}
       {cleanupService}
    }

# -------------------------------------------------------------------------

    SrmManager instproc init {} {
    }

# -------------------------------------------------------------------------

    SrmManager instproc process {connection input} {
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

    SrmManager instproc createRequest {connection requestType isSync SURLS {dstSURLS {}} {sizes {}} {certProxies {}} {depth 0}} {

        set requestId [NewUniqueId]
        set requestObj [self]::${requestId}

        if {[my exists cleanupService]} {
            [my cleanupService] addObject $requestObj
        }

        set submitTime [clock seconds]

        SrmRequest $requestObj \
	    -requestState SRM_REQUEST_QUEUED \
	    -isSyncRequest $isSync \
            -queueSize 0 \
            -requestType $requestType \
            -requestToken $requestId \
            -connection $connection

        set userName [$connection set userName]

        foreach SURL $SURLS dstSURL $dstSURLS size $sizes  {

            set fileId [NewUniqueId]
            set fileObj ${requestObj}::${fileId}

            if {$size == {}} {
                set size 0
            }

            SrmFile $fileObj \
                -frontendService [my frontendService] \
                -fileState SRM_REQUEST_QUEUED \
                -submitTime $submitTime \
                -depth $depth \
                -fileSize $size \
                -SURL $SURL \
                -dstSURL $dstSURL \
                -userName $userName

            $requestObj incr queueSize

            $fileObj $requestType
        }

        if {! $isSync} {
            $connection respond [${requestType}ResBody $requestObj]
        }
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmPing {connection argValues} {
        $connection respond [srmPingResBody]
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmLs {connection argValues} {
        set depth 1
        if {[dict exists $argValues numOfLevels]} {
            set depth [dict get $argValues numOfLevels]
        }

        my createRequest $connection srmLs 1 \
           [dict get $argValues arrayOfSURLs] \
           {} {} {} $depth
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmRm {connection argValues} {
        my createRequest $connection srmRm 1 [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmMkdir {connection argValues} {
        my createRequest $connection srmMkdir 1 [dict get $argValues SURL]
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmRmdir {connection argValues} {
        my createRequest $connection srmRmdir 1 [dict get $argValues SURL]
    }


# -------------------------------------------------------------------------

    SrmManager instproc srmPrepareToGet {connection argValues} {
        set SURLS [list]
        foreach request [dict get $argValues arrayOfFileRequests] {
            lappend SURLS [dict get $request sourceSURL]
        }
        my createRequest $connection srmPrepareToGet 0 $SURLS
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmPrepareToPut {connection argValues} {
        set SURLS [list]
        set sizes [list]
        foreach request [dict get $argValues arrayOfFileRequests] {
            lappend SURLS [dict get $request targetSURL]
            lappend sizes [dict get $request expectedFileSize]
        }
        my createRequest $connection srmPrepareToPut 0 $SURLS $SURLS $sizes
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmStatusOfGetRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]

        if {[dict exists $argValues arrayOfSourceSURLs]} {
            my sendStatus $connection $requestToken srmStatusOfGetRequest \
               [dict get $argValues arrayOfSourceSURLs]
        } else {
            my sendStatus $connection $requestToken srmStatusOfGetRequest {}
        }
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmStatusOfPutRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]

        if {[dict exists $argValues arrayOfTargetSURLs]} {
            my sendStatus $connection $requestToken srmStatusOfPutRequest \
               [dict get $argValues arrayOfTargetSURLs]
        } else {
            my sendStatus $connection $requestToken srmStatusOfPutRequest {}
        }
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmReleaseFiles {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmReleaseFiles \
	    Done [dict get $argValues arrayOfSURLs]
    }


# -------------------------------------------------------------------------

    SrmManager instproc srmPutDone {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmPutDone \
	    Done [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmAbortFiles {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmAbortFiles \
	    Canceled [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    SrmManager instproc srmAbortRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmAbortRequest Canceled {}
    }

# -------------------------------------------------------------------------

    SrmManager instproc sendStatus {connection requestToken requestType SURLS} {

        set requestObj [self]::${requestToken}
        if {! [Object isobject $requestObj]} {
            $connection respond [srmStatusResBody $requestType SRM_INVALID_REQUEST {Unknown request token}]
            return
        }

        set currentTime [clock seconds]

        if {[llength $SURLS] == 0} {
            set files [$requestObj info children]

            foreach fileObj $files {
                $fileObj updateTime $currentTime
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

                $fileObj updateTime $currentTime

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

    SrmManager instproc releaseFiles {connection requestToken requestType explanation SURLS} {

        set requestObj [self]::${requestToken}
        if {! [Object isobject $requestObj]} {
            $connection respond [srmStatusResBody $requestType SRM_INVALID_REQUEST {Unknown request token}]
            return
        }

        if {[llength $SURLS] == 0} {
            set files [$requestObj info children]

            foreach fileObj $files {
                $fileObj abort $explanation
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

                $fileObj abort $explanation

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
        rmdir     {Ready success Failed failure}
        get       {Ready success Failed failure}
        put       {Ready success Failed failure}
        abort     {Ready success}
        failure   {Failed failure}
    }

# -------------------------------------------------------------------------

    Class SrmFile -superclass Notifier -parameter {
        {fileState SRM_REQUEST_QUEUED}
        {submitTime}
        {lifeTime 7200}
        {waitTime 1}
        {counter 1}
        {depth 1}
        {fileSize 0}
        {SURL}
        {dstSURL}
        {TURL}
        {userName}
        {frontendService}
    }

# -------------------------------------------------------------------------

    SrmFile instproc init {} {
        my instvar submitTime finishTime lifeTime
        if {[my exists submitTime]} {
            set finishTime [expr {$submitTime + $lifeTime}]
        } else {
            error {submitTime must be specified}
        }
        next
    }

# -------------------------------------------------------------------------

    SrmFile instproc log {level args} {
        my instvar host
        log::log $level [join $args { }]
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

    SrmFile instproc updateTime {currentTime} {
        my instvar counter submitTime finishTime lifeTime waitTime

	incr counter
        set waitTime [expr {$counter / 4 * 5 + 1}]

        if {$lifeTime > 0} {
            set lifeTime [expr {$finishTime - $currentTime}]
            if {$lifeTime <= 0} {
                set lifeTime 0
                my set fileState SRM_FILE_LIFETIME_EXPIRED
            }
        }
    }

# -------------------------------------------------------------------------

    SrmFile instproc notify {method} {
        after 0 [list [my info parent] $method]
    }

# -------------------------------------------------------------------------

    SrmFile instproc failure {} {
        my done
        my notify failureCallback
    }

# -------------------------------------------------------------------------

    SrmFile instproc success {} {
        my done
        my notify successCallback
    }


# -------------------------------------------------------------------------

    SrmFile instproc abort {reason} {
        my set fileState SRM_SUCCESS
        my set fileStateComment $reason
        my set state abort
    }

# -------------------------------------------------------------------------

    SrmFile instproc done {} {
        my set state done
    }

# -------------------------------------------------------------------------

    SrmFile instproc srmLs {} {
        my instvar userName depth SURL

        my set state ls
        [my frontendService] process [list ls [self] $userName $depth $SURL]
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

    SrmFile instproc srmRmdir {} {
        my instvar userName SURL

        my set state rmdir
        [my frontendService] process [list rmdir [self] $userName $SURL]
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

    SrmFile instproc rmdirSuccess {result} {
        my set fileState SRM_SUCCESS
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc rmdirFailure {reason} {
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
        my set TURL "gsiftp://[TransferHost]:2811/$result"
        my updateState Ready
    }

# -------------------------------------------------------------------------

    SrmFile instproc putFailure {reason} {
        my set fileState SRM_INVALID_PATH
        my set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    namespace export SrmManager
}

package provide srmlite::srm::server 0.1
