package require g2lite

package require srmlite::utilities
namespace import ::srmlite::utilities::Extract*

# -------------------------------------------------------------------------

proc nillableValue {tag var} {
  variable g2result
  upvar $var value
  if {[info exists value]} {
      append g2result {>} $value {</} $tag
  } else {
      append g2result { xsi:nil="true"/}
  }
}

# -------------------------------------------------------------------------

proc InitTemplateHeaders {} {

  set fid [open templates/srm_headers.g2]
  set content [read $fid]
  close $fid

  proc srmHeaders {requestType} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateError {} {

  set fid [open templates/srm_error.g2]
  set content [read $fid]
  close $fid

  proc srmErrorBody {code text url} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateFault {} {

  set fid [open templates/srm_fault.g2]
  set content [read $fid]
  close $fid

  proc srmFaultBody {faultString stackTrace} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmStatusRes {} {

  set fid [open templates/srmStatus_res.g2]
  set content [read $fid]
  close $fid

  proc srmStatusResBody {requestType requestState explanation} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPingReq {} {

  set fid [open templates/srmPing_req.g2]
  set content [read $fid]
  close $fid

  proc srmPingReqBody {} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPingRes {} {

  set fid [open templates/srmPing_res.g2]
  set content [read $fid]
  close $fid

  proc srmPingResBody {} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmLsReq {} {

  set fid [open templates/srmLs_req.g2]
  set content [read $fid]
  close $fid

  proc srmLsReqBody {SURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmLsRes {} {

  set fid [open templates/srmLs_res.g2]
  set content [read $fid]
  close $fid

  proc srmLsResBody {request} [g2lite $content]
}


# -------------------------------------------------------------------------

proc InitTemplateSrmRmReq {} {

  set fid [open templates/srmRm_req.g2]
  set content [read $fid]
  close $fid

  proc srmRmReqBody {SURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmRmRes {} {

  set fid [open templates/srmRm_res.g2]
  set content [read $fid]
  close $fid

  proc srmRmResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmMkdirReq {} {

  set fid [open templates/srmMkdir_req.g2]
  set content [read $fid]
  close $fid

  proc srmMkdirReqBody {SURL} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmMkdirRes {} {

  set fid [open templates/srmRequestStatus_res.g2]
  set content [read $fid]
  close $fid

  proc srmMkdirResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPrepareToGetReq {} {

  set fid [open templates/srmPrepareToGet_req.g2]
  set content [read $fid]
  close $fid

  proc srmPrepareToGetReqBody {srcSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPrepareToGetRes {} {

  set fid [open templates/srmPrepareToGet_res.g2]
  set content [read $fid]
  close $fid

  proc srmPrepareToGetResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPrepareToPutReq {} {

  set fid [open templates/srmPrepareToPut_req.g2]
  set content [read $fid]
  close $fid

  proc srmPrepareToPutReqBody {dstSURLS sizes} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPrepareToPutRes {} {

  set fid [open templates/srmPrepareToPut_res.g2]
  set content [read $fid]
  close $fid

  proc srmPrepareToPutResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmStatusOfGetRequestReq {} {

  set fid [open templates/srmStatusOfGetRequest_req.g2]
  set content [read $fid]
  close $fid

  proc srmStatusOfGetRequestReqBody {requestToken srcSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmStatusOfGetRequestRes {} {

  set fid [open templates/srmStatusOfGetRequest_res.g2]
  set content [read $fid]
  close $fid

  proc srmStatusOfGetRequestResBody {request files} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmStatusOfPutRequestReq {} {

  set fid [open templates/srmStatusOfPutRequest_req.g2]
  set content [read $fid]
  close $fid

  proc srmStatusOfPutRequestReqBody {requestToken dstSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmStatusOfPutRequestRes {} {

  set fid [open templates/srmStatusOfPutRequest_res.g2]
  set content [read $fid]
  close $fid

  proc srmStatusOfPutRequestResBody {request files} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmReleaseFilesReq {} {

  set fid [open templates/srmReleaseFiles_req.g2]
  set content [read $fid]
  close $fid

  proc srmReleaseFilesReqBody {requestToken srcSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmReleaseFilesRes {} {

  set fid [open templates/srmReleaseFiles_res.g2]
  set content [read $fid]
  close $fid

  proc srmReleaseFilesResBody {request files} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPutDoneReq {} {

  set fid [open templates/srmPutDone_req.g2]
  set content [read $fid]
  close $fid

  proc srmPutDoneReqBody {requestToken srcSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPutDoneRes {} {

  set fid [open templates/srmPutDone_res.g2]
  set content [read $fid]
  close $fid

  proc srmPutDoneResBody {request files} [g2lite $content]
}
# -------------------------------------------------------------------------

proc InitTemplateSrmAbortFilesReq {} {

  set fid [open templates/srmAbortFiles_req.g2]
  set content [read $fid]
  close $fid

  proc srmAbortFilesReqBody {requestToken SURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmAbortFilesRes {} {

  set fid [open templates/srmAbortFiles_res.g2]
  set content [read $fid]
  close $fid

  proc srmAbortFilesResBody {request files} [g2lite $content]
}

# -------------------------------------------------------------------------

InitTemplateHeaders
InitTemplateError
InitTemplateFault

InitTemplateSrmStatusRes

InitTemplateSrmPingReq
InitTemplateSrmPingRes

InitTemplateSrmLsReq
InitTemplateSrmLsRes
InitTemplateSrmRmReq
InitTemplateSrmRmRes
InitTemplateSrmMkdirReq
InitTemplateSrmMkdirRes

InitTemplateSrmPrepareToGetReq
InitTemplateSrmPrepareToGetRes
InitTemplateSrmPrepareToPutReq
InitTemplateSrmPrepareToPutRes

InitTemplateSrmStatusOfGetRequestReq
InitTemplateSrmStatusOfGetRequestRes
InitTemplateSrmStatusOfPutRequestReq
InitTemplateSrmStatusOfPutRequestRes

InitTemplateSrmReleaseFilesReq
InitTemplateSrmReleaseFilesRes
InitTemplateSrmPutDoneReq
InitTemplateSrmPutDoneRes
InitTemplateSrmAbortFilesReq
InitTemplateSrmAbortFilesRes

# -------------------------------------------------------------------------

package provide srmlite::templates 0.2
