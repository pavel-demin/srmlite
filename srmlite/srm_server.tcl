package require log
package require tdom
package require TclOO

package require srmlite::utilities
package require srmlite::templates
package require srmlite::soap

namespace eval ::srmlite::srm::server {
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

    oo::class create SrmManager

# -------------------------------------------------------------------------

    oo::define SrmManager method constructor {} {
        my variable frontendService cleanupService

        foreach {param value} $args {
            if {$param eq "-frontendService"} {
                set frontendService $value
            } elseif {$param eq "-cleanupService"} {
                set cleanupService $value
            } else {
                error "unsupported parameter $param"
            }
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method process {connection input} {
        global errorInfo
        variable methods

        set soapaction [info object namespace $connection]::mime(soapaction)
        if {[info exists $soapaction]} {
            set action [set $soapaction]
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

    oo::define SrmManager method createRequest {connection requestType isSync SURLS {dstSURLS {}} {sizes {}} {depth 0}} {
        my variable frontendService cleanupService

        set requestId [NewUniqueId]
        set requestObj [self]::${requestId}

        if {[info exists cleanupService]} {
            $cleanupService addObject $requestObj
        }

        set submitTime [clock seconds]

        SrmRequest create $requestObj \
            -requestState SRM_REQUEST_QUEUED \
            -isSyncRequest $isSync \
            -queueSize 0 \
            -requestType $requestType \
            -requestToken $requestId \
            -connection $connection

        set userName [set [info object namespace $connection]::userName]

        foreach SURL $SURLS dstSURL $dstSURLS size $sizes {

            set fileId [NewUniqueId]
            set fileObj ${requestObj}::${fileId}

            if {$size == {}} {
                set size 0
            }

            SrmFile create $fileObj \
                -parent $requestObj \
                -frontendService $frontendService \
                -fileState SRM_REQUEST_QUEUED \
                -submitTime $submitTime \
                -depth $depth \
                -fileSize $size \
                -SURL $SURL \
                -dstSURL $dstSURL \
                -userName $userName

            incr [info object namespace $requestObj]::queueSize

            $fileObj $requestType
        }

        if {! $isSync} {
            $connection respond [${requestType}ResBody $requestObj]
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmPing {connection argValues} {
        $connection respond [srmPingResBody]
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmLs {connection argValues} {
        set depth 1

        if {[dict exists $argValues numOfLevels]} {
            set depth [dict get $argValues numOfLevels]
        }

        my createRequest $connection srmLs 1 \
           [dict get $argValues arrayOfSURLs] \
           {} {} $depth
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmRm {connection argValues} {
        my createRequest $connection srmRm 1 [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmMkdir {connection argValues} {
        my createRequest $connection srmMkdir 1 [dict get $argValues SURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmRmdir {connection argValues} {
        my createRequest $connection srmRmdir 1 [dict get $argValues SURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmPrepareToGet {connection argValues} {
        set SURLS [list]
        foreach request [dict get $argValues arrayOfFileRequests] {
            lappend SURLS [dict get $request sourceSURL]
        }
        my createRequest $connection srmPrepareToGet 0 $SURLS
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmPrepareToPut {connection argValues} {
        set SURLS [list]
        set sizes [list]
        foreach request [dict get $argValues arrayOfFileRequests] {
            lappend SURLS [dict get $request targetSURL]
            lappend sizes [dict get $request expectedFileSize]
        }
        my createRequest $connection srmPrepareToPut 0 $SURLS $SURLS $sizes
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmStatusOfGetRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        if {[dict exists $argValues arrayOfSourceSURLs]} {
            my sendStatus $connection $requestToken srmStatusOfGetRequest \
               [dict get $argValues arrayOfSourceSURLs]
        } else {
            my sendStatus $connection $requestToken srmStatusOfGetRequest {}
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmStatusOfPutRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        if {[dict exists $argValues arrayOfTargetSURLs]} {
            my sendStatus $connection $requestToken srmStatusOfPutRequest \
               [dict get $argValues arrayOfTargetSURLs]
        } else {
            my sendStatus $connection $requestToken srmStatusOfPutRequest {}
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmReleaseFiles {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmReleaseFiles \
            Done [dict get $argValues arrayOfSURLs]
    }


# -------------------------------------------------------------------------

    oo::define SrmManager method srmPutDone {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmPutDone \
            Done [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmAbortFiles {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmAbortFiles \
            Canceled [dict get $argValues arrayOfSURLs]
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method srmAbortRequest {connection argValues} {
        set requestToken [dict get $argValues requestToken]
        my releaseFiles $connection $requestToken srmAbortRequest Canceled {}
    }

# -------------------------------------------------------------------------

    oo::define SrmManager method sendStatus {connection requestToken requestType SURLS} {
        set requestObj [self]::${requestToken}

        if {! [info object isa object $requestObj]} {
            $connection respond [srmStatusResBody $requestType SRM_INVALID_REQUEST {Unknown request token}]
            return
        }

        set currentTime [clock seconds]

        if {[llength $SURLS] == 0} {
            set files [$requestObj getFiles]

            foreach fileObj $files {
                $fileObj updateTime $currentTime
            }

            $connection respond [${requestType}ResBody $requestObj $files]
            return
        }

        set requestId [NewUniqueId]
        set requestState [set [info object namespace $requestObj]::requestState]
        set requestTmp [self]::${requestId}

        SrmRequest $requestTmp \
            -requestState $requestState \
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

    oo::define SrmManager method releaseFiles {connection requestToken requestType explanation SURLS} {

        set requestObj [self]::${requestToken}
        if {! [info object isa object $requestObj]} {
            $connection respond [srmStatusResBody $requestType SRM_INVALID_REQUEST {Unknown request token}]
            return
        }

        if {[llength $SURLS] == 0} {
            set files [$requestObj getFiles]
            foreach fileObj $files {
                $fileObj abort $explanation
            }
            $connection respond [${requestType}ResBody $requestObj $files]
            return
        }

        set requestId [NewUniqueId]
        set requestState [set [$requestObj varname requestState]]
        set requestTmp [self]::${requestId}

        SrmRequest $requestTmp \
            -requestState requestState \
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

    oo::class create SrmRequest

# -------------------------------------------------------------------------

    oo::define SrmRequest constructor {} {
        my variable requestState isSyncRequest queueSize
        my variable requestType requestToken connection
        my variable successFlag failureFlag fileDict

        set requestState SRM_REQUEST_QUEUED
        set isSyncRequest 0
        set queueSize 0

        set successFlag 0
        set failureFlag 0
        set fileDict [dict create]

        foreach {param value} $args {
            if {$param eq "-requestState"} {
                set requestState $value
            } elseif {$param eq "-isSyncRequest"} {
                set isSyncRequest $value
            } elseif {$param eq "-queueSize"} {
                set queueSize $value
            } elseif {$param eq "-requestType"} {
                set requestType $value
            } elseif {$param eq "-requestToken"} {
                set requestToken $value
            } elseif {$param eq "-connection"} {
                set connection $value
            } else {
                error "unsupported parameter $param"
            }
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmRequest method setFile {SURL obj} {
        my variable fileDict
        dict set fileDict $SURL $obj
    }

# -------------------------------------------------------------------------

    oo::define SrmRequest method getFiles {} {
        my variable fileDict
        dict values $fileDict
    }

# -------------------------------------------------------------------------

    oo::define SrmRequest method getFile {SURL} {
        my variable fileDict
        dict get $fileDict $SURL
    }

# -------------------------------------------------------------------------

    oo::define SrmRequest method existsFile {SURL} {
        my variable fileDict
        dict exists $fileDict $SURL
    }

# -------------------------------------------------------------------------

    oo::define SrmRequest method updateState {} {
        my variable requestState isSyncRequest queueSize
        my variable requestType connection
        my variable successFlag failureFlag

        if {$queueSize > 0} {
            set requestState SRM_REQUEST_INPROGRESS
            return
        }

        if {$successFlag && ! $failureFlag} {
            set requestState SRM_SUCCESS
        } elseif {! $successFlag && $failureFlag} {
            set requestState SRM_FAILURE
        } else {
            set requestState SRM_PARTIAL_SUCCESS
        }

        if {$isSyncRequest} {
            if {[info object isa object $connection]} {
                $connection respond [${requestType}ResBody [self]]
            }
            my destroy
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmRequest method successCallback {result} {
        my variable successFlag queueSize
        set successFlag 1
        incr queueSize -1
        my updateState
    }

# -------------------------------------------------------------------------

    oo::define SrmRequest method failureCallback {reason} {
        my variable failureFlag queueSize
        set failureFlag 1
        incr queueSize -1
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
        getDone   {Ready success}
        putDone   {Ready success}
        abort     {Ready success}
        failure   {Failed failure}
    }

# -------------------------------------------------------------------------

    oo::class create SrmFile

# -------------------------------------------------------------------------

    oo::define SrmFile constructor {} {
        my variable parent fileState submitTime lifeTime waitTime counter
        my variable depth fileSize SURL dstSURL TURL userName frontendService
        my variable finishTime

        foreach {param value} $args {
            if {$param eq "-parent"} {
                set parent $value
            } elseif {$param eq "-fileState"} {
                set fileState $value
            } elseif {$param eq "-submitTime"} {
                set submitTime $value
            } elseif {$param eq "-lifeTime"} {
                set lifeTime $value
            } elseif {$param eq "-waitTime"} {
                set waitTime $value
            } elseif {$param eq "-counter"} {
                set counter $value
            } elseif {$param eq "-depth"} {
                set depth $value
            } elseif {$param eq "-fileSize"} {
                set fileSize $value
            } elseif {$param eq "-SURL"} {
                set SURL $value
            } elseif {$param eq "-dstSURL"} {
                set dstSURL $value
            } elseif {$param eq "-TURL"} {
                set TURL $value
            } elseif {$param eq "-userName"} {
                set userName $value
            } elseif {$param eq "-frontendService"} {
                set frontendService $value
            } else {
                error "unsupported parameter $param"
            }
        }

        if {[info exists submitTime]} {
            set finishTime [expr {$submitTime + $lifeTime}]
        } else {
            error {submitTime must be specified}
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method log {level args} {
        my variable host
        log::log $level [join $args { }]
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method updateState {code} {
        my variable state faultString
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

    oo::define SrmFile method updateTime {currentTime} {
        my variable fileState counter submitTime finishTime lifeTime waitTime

        incr counter
        set waitTime [expr {$counter / 4 * 5 + 1}]

        if {$lifeTime > 0} {
            set lifeTime [expr {$finishTime - $currentTime}]
            if {$lifeTime <= 0} {
                set lifeTime 0
                set fileState SRM_FILE_LIFETIME_EXPIRED
            }
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method notify {method} {
        my variable parent

        if {[info exists parent]} {
            after 0 [list $parent $method]
        }
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method success {} {
        my done
        my notify successCallback
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method failure {} {
        my done
        my notify failureCallback
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method getDone {} {
        my variable fileState state

        set fileState SRM_SUCCESS
        set state getDone
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method putDone {} {
        my variable fileState state

        my set fileState SRM_SUCCESS
        my set state putDone
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method abort {reason} {
        my variable fileState fileStateComment state

        set fileState SRM_SUCCESS
        set fileStateComment $reason
        set state abort
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method done {} {
        my variable state

        set state done
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method srmLs {} {
        my variable depth SURL userName frontendService state

        set state ls
        $frontendService process [list ls [self] $userName $depth $SURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method srmRm {} {
        my variable SURL userName frontendService state

        set state rm
        $frontendService process [list rm [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method srmMkdir {} {
        my variable SURL userName frontendService state

        set state mkdir
        $frontendService process [list mkdir [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method srmRmdir {} {
        my variable SURL userName frontendService state

        set state rmdir
        $frontendService process [list rmdir [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method srmPrepareToGet {} {
        my variable parent SURL userName frontendService state

        set state get
        $parent setFile $SURL [self]
        $frontendService process [list get [self] $userName $SURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method srmPrepareToPut {} {
        my variable parent dstSURL userName frontendService state

        set state put
        $parent setFile $dstSURL [self]
        $frontendService process [list put [self] $userName $dstSURL]
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method lsSuccess {result} {
        my variable fileState metadata

        set fileState SRM_SUCCESS
        set metadata $result
        my updateState Ready
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method lsFailure {reason} {
        my variable fileState fileStateComment

        set fileState SRM_INVALID_PATH
        set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method rmSuccess {result} {
        my variable fileState

        set fileState SRM_SUCCESS
        my updateState Ready
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method rmFailure {reason} {
        my variable fileState fileStateComment

        set fileState SRM_FAILURE
        set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method mkdirSuccess {result} {
        my variable fileState

        set fileState SRM_SUCCESS
        my updateState Ready
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method mkdirFailure {reason} {
        my variable fileState fileStateComment

        set fileState SRM_FAILURE
        set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method rmdirSuccess {result} {
        my variable fileState

        set fileState SRM_SUCCESS
        my updateState Ready
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method rmdirFailure {reason} {
        my variable fileState fileStateComment

        set fileState SRM_FAILURE
        set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method getSuccess {result} {
        my variable fileSize SURL TURL fileState

        set fileState SRM_FILE_PINNED
        set fileSize [lindex [lindex $result 0] 4]
        set TURL [ConvertSURL2TURL $SURL]
        my updateState Ready
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method getFailure {reason} {
        my variable fileState fileStateComment

        set fileState SRM_INVALID_PATH
        set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method putSuccess {result} {
        my variable TURL fileState

        set fileState SRM_SPACE_AVAILABLE
        set TURL "gsiftp://[TransferHost]:2811/$result"
        my updateState Ready
    }

# -------------------------------------------------------------------------

    oo::define SrmFile method putFailure {reason} {
        my variable fileState fileStateComment

        set fileState SRM_INVALID_PATH
        set fileStateComment [join $reason { }]
        my updateState Failed
    }

# -------------------------------------------------------------------------

    namespace export SrmManager
}

package provide srmlite::srm::server 0.2
