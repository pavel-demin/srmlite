# -------------------------------------------------------------------------

proc InitTemplateHeaders {} {

  set fid [open template_srm_headers.g2]
  set content [read $fid]
  close $fid

  proc SrmHeaders {requestType} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateFault {} {

  set fid [open template_srm_fault.g2]
  set content [read $fid]
  close $fid

  proc SrmFaultBody {faultString stackTrace} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateStatus {} {

  set fid [open template_srm_status.g2]
  set content [read $fid]
  close $fid

  proc SrmStatusBody {responseType requestId} [g2lite $content]

}

# -------------------------------------------------------------------------

proc InitTemplateFileMetaData {} {

  set fid [open template_srm_metadata.g2]
  set content [read $fid]
  close $fid

  proc SrmFileMetaDataBody {requestId} [g2lite $content]

}

# -------------------------------------------------------------------------

proc InitTemplateGetRequestStatus {} {

  set fid [open template_srm_getRequestStatus.g2]
  set content [read $fid]
  close $fid

  proc SrmGetRequestStatusBody {requestId} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateSetFileStatus {} {

  set fid [open template_srm_setFileStatus.g2]
  set content [read $fid]
  close $fid

  proc SrmSetFileStatusBody {requestId fileId fileState} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateAdvisoryDelete {} {

  set fid [open template_srm_advisoryDelete.g2]
  set content [read $fid]
  close $fid

  proc SrmAdvisoryDeleteBody {srcSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateGetFileMetaData {} {

  set fid [open template_srm_getFileMetaData.g2]
  set content [read $fid]
  close $fid

  proc SrmGetFileMetaDataBody {srcSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateGet {} {

  set fid [open template_srm_get.g2]
  set content [read $fid]
  close $fid

  proc SrmGetBody {srcSURLS} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplatePut {} {

  set fid [open template_srm_put.g2]
  set content [read $fid]
  close $fid

  proc SrmPutBody {dstSURL size} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplateCopy {} {

  set fid [open template_srm_copy.g2]
  set content [read $fid]
  close $fid

  proc SrmCopyBody {srcSURL dstSURL} [g2lite $content]
}

# -------------------------------------------------------------------------

proc InitTemplatePingResponse {} {

  set fid [open template_srm_pingResponse.g2]
  set content [read $fid]
  close $fid

  proc SrmPingResponseBody {} [g2lite $content]
}

# -------------------------------------------------------------------------

InitTemplateHeaders
InitTemplateFault
InitTemplateStatus
InitTemplateFileMetaData
InitTemplateGetRequestStatus
InitTemplateSetFileStatus
InitTemplateAdvisoryDelete
InitTemplateGetFileMetaData
InitTemplateGet
InitTemplatePut
InitTemplateCopy
InitTemplatePing
InitTemplatePingResponse

# -------------------------------------------------------------------------

package provide srmlite::templates 0.1
