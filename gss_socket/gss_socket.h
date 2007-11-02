
/*
  Copyright (c) 2007, Pavel Demin

  All rights reserved.

  Redistribution and use in source and binary forms,
  with or without modification, are permitted
  provided that the following conditions are met:

      * Redistributions of source code must retain
        the above copyright notice, this list of conditions
        and the following disclaimer.
      * Redistributions in binary form must reproduce
        the above copyright notice, this list of conditions
        and the following disclaimer in the documentation
        and/or other materials provided with the distribution.
      * Neither the name of the SRMlite nor the names of its
        contributors may be used to endorse or promote products
        derived from this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#ifndef GSS_CONTEXT_H
#define GSS_CONTEXT_H

/* ----------------------------------------------------------------- */

#define GSS_TCL_BLOCKING    (1<<0)  /* non-blocking mode */
#define GSS_TCL_SERVER      (1<<1)  /* server-side */
#define GSS_TCL_READHEADER  (1<<2)
#define GSS_TCL_HANDSHAKE   (1<<3)
#define GSS_TCL_INPUTERROR  (1<<4)
#define GSS_TCL_OUTPUTERROR (1<<5)
#define GSS_TCL_EOF         (1<<6)

#define GSS_TCL_DELAY     (5)

/* ----------------------------------------------------------------- */

typedef struct GssState {
  Tcl_Channel parent;
  Tcl_Channel channel;
  Tcl_TimerToken timer;
  Tcl_DriverGetOptionProc *parentGetOptionProc;
  Tcl_DriverBlockModeProc *parentBlockModeProc;
  Tcl_DriverWatchProc *parentWatchProc;
  ClientData parentInstData;

  int flags;
  int errorCode;
  int intWatchMask;
  int extWatchMask;

  gss_cred_id_t gssCredential;
  gss_cred_id_t gssDelegProxy;
  gss_buffer_desc gssDelegProxyFileName;
  int gssDelegProxyFileNamePos;
  gss_ctx_id_t gssContext;
  gss_name_t gssName;
  gss_buffer_desc gssNameBuf;
  OM_uint32 gssFlags;
  OM_uint32 gssTime;
  char *gssUser;

  OM_uint32 readRawBufSize;
  gss_buffer_desc readRawBuf; /* should be allocated in import */
  gss_buffer_desc readOutBuf; /* allocated by gss */
  int readRawBufPos;
  int readOutBufPos;

  OM_uint32 writeInBufSize;
  unsigned char writeTokenSizeBuf[4];
  gss_buffer_desc writeRawBuf; /* allocated by gss */
  gss_buffer_desc writeInBuf;  /* should be allocated in import */
  int writeRawBufPos;

  Tcl_Interp *interp;	/* interpreter in which this resides */
} GssState;

/* ----------------------------------------------------------------- */

#endif /* GSS_CONTEXT_H */

