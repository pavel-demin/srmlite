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

proc InitTemplateSrmPingRes {} {

  set fid [open templates/srmPing_res.g2]
  set content [read $fid]
  close $fid

  proc srmPingResBody {} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmLsRes {} {

  set fid [open templates/srmLs_res.g2]
  set content [read $fid]
  close $fid

  proc srmLsResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmRmRes {} {

  set fid [open templates/srmRm_res.g2]
  set content [read $fid]
  close $fid

  proc srmRmResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmMkdirRes {} {

  set fid [open templates/srmRequestStatus_res.g2]
  set content [read $fid]
  close $fid

  proc srmMkdirResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPrepareToGetRes {} {

  set fid [open templates/srmPrepareToGet_res.g2]
  set content [read $fid]
  close $fid

  proc srmPrepareToGetResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPrepareToPutRes {} {

  set fid [open templates/srmPrepareToPut_res.g2]
  set content [read $fid]
  close $fid

  proc srmPrepareToPutResBody {request} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmStatusOfGetRequestRes {} {

  set fid [open templates/srmStatusOfGetRequest_res.g2]
  set content [read $fid]
  close $fid

  proc srmStatusOfGetRequestResBody {request files} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmStatusOfPutRequestRes {} {

  set fid [open templates/srmStatusOfPutRequest_res.g2]
  set content [read $fid]
  close $fid

  proc srmStatusOfPutRequestResBody {request files} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmReleaseFilesRes {} {

  set fid [open templates/srmReleaseFiles_res.g2]
  set content [read $fid]
  close $fid

  proc srmReleaseFilesResBody {request files} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSrmPutDoneRes {} {

  set fid [open templates/srmPutDone_res.g2]
  set content [read $fid]
  close $fid

  proc srmPutDoneResBody {request files} [g2lite $content]
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

InitTemplateSrmPingRes

InitTemplateSrmLsRes
InitTemplateSrmRmRes
InitTemplateSrmMkdirRes

InitTemplateSrmPrepareToGetRes
InitTemplateSrmPrepareToPutRes

InitTemplateSrmStatusOfGetRequestRes
InitTemplateSrmStatusOfPutRequestRes

InitTemplateSrmReleaseFilesRes
InitTemplateSrmPutDoneRes
InitTemplateSrmAbortFilesRes

# -------------------------------------------------------------------------

package provide srmlite::templates 0.2
