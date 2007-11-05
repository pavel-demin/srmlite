
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

#include <tcl.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>

#include <gssapi.h>
#include <globus_gss_assist.h>

#include "gss_socket.h"

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

static int	GssBlockModeProc(ClientData instanceData, int mode);
static int	GssCloseProc(ClientData instanceData, Tcl_Interp *interp);
static int	GssInputProc(ClientData instanceData, char *buf, int bufSize, int *errorCodePtr);
static int	GssOutputProc(ClientData instanceData, CONST char *buf, int toWrite, int *errorCodePtr);
static int	GssGetOptionProc(ClientData instanceData, Tcl_Interp *interp, CONST char *optionName, Tcl_DString *dsPtr);
static void	GssWatchProc(ClientData instanceData, int mask);
static int	GssNotifyProc(ClientData instanceData, int mask);

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
  gss_cred_id_t gssCredProxy;
  gss_buffer_desc gssCredFileName;
  int gssCredFileNamePos;
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

static Tcl_ChannelType ChannelType = {
  "gss",
  TCL_CHANNEL_VERSION_2,
  GssCloseProc,
  GssInputProc,
  GssOutputProc,
  NULL,		/* Seek proc. */
  NULL,		/* Set option proc. */
  GssGetOptionProc,
  GssWatchProc,
  NULL,   /* Get file handle out of channel. */
  NULL,   /* Close2Proc. */
  GssBlockModeProc,
  NULL,		/* FlushProc. */
  GssNotifyProc
};

/* ----------------------------------------------------------------- */

static int GssWriteToken(GssState *statePtr);
static int GssReadToken(GssState *statePtr);

/* ----------------------------------------------------------------- */

static int
GssBlockModeProc(ClientData instanceData,	int mode)
{
  GssState *statePtr = (GssState *) instanceData;

  if(mode == TCL_MODE_NONBLOCKING)
  {
    statePtr->flags &= ~(GSS_TCL_BLOCKING);
  }
  else
  {
    statePtr->flags |= GSS_TCL_BLOCKING;
  }

	return 0;
}

/* ----------------------------------------------------------------- */

static void
GssClean(GssState *statePtr)
{
  OM_uint32 majorStatus, minorStatus;

  if(statePtr->timer != (Tcl_TimerToken) NULL)
  {
    Tcl_DeleteTimerHandler(statePtr->timer);
    statePtr->timer = NULL;
  }

  if(statePtr->gssContext != GSS_C_NO_CONTEXT)
  {
    majorStatus = gss_delete_sec_context(&minorStatus,
                                         &statePtr->gssContext,
                                         GSS_C_NO_BUFFER);
  }

  if(statePtr->gssCredential != GSS_C_NO_CREDENTIAL)
  {
    majorStatus = gss_release_cred(&minorStatus,
                                   &statePtr->gssCredential);
  }

  if(statePtr->gssCredProxy != GSS_C_NO_CREDENTIAL)
  {
    majorStatus = gss_release_cred(&minorStatus,
                                   &statePtr->gssCredProxy);
  }

  if(statePtr->gssCredFileName.value != NULL)
  {
    majorStatus = gss_release_buffer(&minorStatus, &statePtr->gssCredFileName);
    statePtr->gssCredFileName.value = NULL;
  }

  if(statePtr->gssName != GSS_C_NO_NAME)
  {
    majorStatus = gss_release_name(&minorStatus,
                                   &statePtr->gssName);
  }

  if(statePtr->gssNameBuf.value != NULL)
  {
    majorStatus = gss_release_buffer(&minorStatus, &statePtr->gssNameBuf);
    statePtr->gssNameBuf.value = NULL;
  }

  if(statePtr->readOutBuf.value != NULL)
  {
    majorStatus = gss_release_buffer(&minorStatus, &statePtr->readOutBuf);
    statePtr->readOutBuf.value = NULL;
  }

  if(statePtr->writeRawBuf.value != NULL)
  {
    majorStatus = gss_release_buffer(&minorStatus, &statePtr->writeRawBuf);
    statePtr->writeRawBuf.value = NULL;
  }

  if(statePtr->writeInBuf.value != NULL)
  {
    ckfree(statePtr->writeInBuf.value);
    statePtr->writeInBuf.value = NULL;
  }

  if(statePtr->readRawBuf.value != NULL)
  {
    ckfree(statePtr->readRawBuf.value);
    statePtr->readRawBuf.value = NULL;
  }

  if(statePtr->gssUser != NULL)
  {
    free(statePtr->gssUser);
    statePtr->gssUser = NULL;
  }
}

/* ----------------------------------------------------------------- */

static int
GssCloseProc(ClientData instanceData,	 Tcl_Interp *interp)
{
  int counter;

  GssState *statePtr = (GssState *) instanceData;

  if(0) printf("---> GssCloseProc(0x%x)\n", (unsigned int) statePtr);

  counter = 0;
  while((counter < 3) &&
        (statePtr->writeRawBuf.length > 0 ||
         statePtr->writeInBuf.length > 0))
  {
    GssWriteToken(statePtr);
    ++counter;
  }

  GssClean(statePtr);

  Tcl_EventuallyFree((ClientData) statePtr, TCL_DYNAMIC);

  return TCL_OK;
}

/* ----------------------------------------------------------------- */

static int
GssInputProc(ClientData instanceData,	char *buf, int bytesToRead,	int *errorCodePtr)
{
  GssState *statePtr = (GssState *) instanceData;
  int bytesRead;

  OM_uint32 majorStatus, minorStatus;

  *errorCodePtr = 0;
  bytesRead = 0;

  if(0) printf("---> Input(%d)", statePtr->flags & GSS_TCL_BLOCKING);

  if(statePtr->flags & GSS_TCL_BLOCKING)
  {
    while(statePtr->flags & GSS_TCL_HANDSHAKE ||
          statePtr->readOutBuf.length == 0 ||
          statePtr->readOutBufPos >= statePtr->readOutBuf.length)
    {
      Tcl_DoOneEvent(TCL_ALL_EVENTS);
    }
  }

  if(statePtr->flags & GSS_TCL_HANDSHAKE)
  {
    if(0) printf("---> Input 1\n");
    *errorCodePtr = EAGAIN;
    bytesRead = -1;
  }
  else if(statePtr->readOutBufPos < statePtr->readOutBuf.length)
  {
    if(0) printf("---> Input 2\n");
    bytesRead = statePtr->readOutBuf.length - statePtr->readOutBufPos;

    if(bytesRead > bytesToRead)
    {
      bytesRead = bytesToRead;
    }

    memcpy(buf, statePtr->readOutBuf.value + statePtr->readOutBufPos, bytesRead);
    statePtr->readOutBufPos += bytesRead;

    if(statePtr->readOutBufPos == statePtr->readOutBuf.length)
    {
      majorStatus = gss_release_buffer(&minorStatus, &statePtr->readOutBuf);
      statePtr->readOutBufPos = 0;
      statePtr->readOutBuf.length = 0;
      statePtr->readOutBuf.value = NULL;
    }
  }
  else if(statePtr->flags & GSS_TCL_EOF)
  {
    if(0) printf("---> Input 3\n");
    statePtr->flags &= ~(GSS_TCL_EOF);
    *errorCodePtr = 0;
    bytesRead = 0;
  }
  else if(statePtr->flags & GSS_TCL_INPUTERROR)
  {
    if(0) printf("---> Input 4\n");
    statePtr->flags &= ~(GSS_TCL_INPUTERROR);
    *errorCodePtr = statePtr->errorCode;
    bytesRead = -1;
  }
  else if(statePtr->readOutBuf.length == 0 ||
          statePtr->readOutBufPos >= statePtr->readOutBuf.length)
  {
    if(0) printf("---> Input 5\n");
    *errorCodePtr = EAGAIN;
    bytesRead = -1;
  }


  if(0) printf("---> Input(%d) -> %d [%d]\n", bytesToRead, bytesRead, *errorCodePtr);
  return bytesRead;
}

/* ----------------------------------------------------------------- */

static int
GssOutputProc(ClientData instanceData, CONST char *buf,	int bytesToWrite, int *errorCodePtr)
{
  GssState *statePtr = (GssState *) instanceData;
  int bytesWritten;

  *errorCodePtr = 0;
  bytesWritten = 0;

  if(0) printf("---> Output(%d)", statePtr->flags & GSS_TCL_BLOCKING);

  if(statePtr->flags & GSS_TCL_BLOCKING)
  {
    while(statePtr->flags & GSS_TCL_HANDSHAKE ||
          statePtr->writeInBuf.length >= statePtr->writeInBufSize)
    {
      Tcl_DoOneEvent(TCL_ALL_EVENTS);
    }
  }

  if(statePtr->flags & GSS_TCL_HANDSHAKE)
  {
    *errorCodePtr = EAGAIN;
    bytesWritten = -1;
  }
  else if(statePtr->flags & GSS_TCL_OUTPUTERROR)
  {
    statePtr->flags &= ~(GSS_TCL_OUTPUTERROR);
    *errorCodePtr = statePtr->errorCode;
    bytesWritten = -1;
  }
  else if(statePtr->writeInBuf.length < statePtr->writeInBufSize)
  {
    bytesWritten = statePtr->writeInBufSize - statePtr->writeInBuf.length;

    if(bytesWritten > bytesToWrite)
    {
      bytesWritten = bytesToWrite;
    }

    memcpy(statePtr->writeInBuf.value + statePtr->writeInBuf.length, buf, bytesWritten);
    statePtr->writeInBuf.length += bytesWritten;

    if(statePtr->writeInBuf.length > 0)
    {
      statePtr->intWatchMask |= TCL_WRITABLE;
    	(*statePtr->parentWatchProc) (statePtr->parentInstData, statePtr->intWatchMask | statePtr->extWatchMask);
    }
  }
  else if(statePtr->writeInBuf.length >= statePtr->writeInBufSize)
  {
    *errorCodePtr = EAGAIN;
    bytesWritten = -1;
  }

  if(0) printf("---> Output(%d) -> %d [%d]\n", bytesToWrite, bytesWritten, *errorCodePtr);
  return bytesWritten;
}

/* ----------------------------------------------------------------- */

static void
GssCredDestroy(ClientData clientData)
{
  OM_uint32 majorStatus, minorStatus;
  GssCred *credPtr = (GssCred *) clientData;

  if(credPtr->gssCredBuf.value != NULL)
  {
    majorStatus = gss_release_buffer(&minorStatus, &credPtr->gssCredBuf);
    credPtr->gssCredBuf.value = NULL;
  }

  ckfree((char *)credPtr);

}

/* ----------------------------------------------------------------- */

static int
GssCredObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
  char *option;

  GssCred *credPtr = (GssCred *) clientData;

  if(objc < 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "command ?arg?");
    return TCL_ERROR;
  }

  option = Tcl_GetStringFromObj(objv[1], NULL);

  if(strcmp(option, "destroy") == 0)
  {
		if(objc != 2)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "destroy");
			return TCL_ERROR;
		}
		Tcl_DeleteCommandFromToken(interp, credPtr->token);
		return TCL_OK;
  }

  Tcl_AppendResult(interp, "bad option \"", option,
    "\": must be destroy", NULL);
	return TCL_ERROR;
}

/* ----------------------------------------------------------------- */

int GssCredGet(Tcl_Interp *interp, char *credName, GssCred **credPtr)
{
  Tcl_CmdInfo cmdInfo;

  if(!Tcl_GetCommandInfo(interp, credName, &cmdInfo))
  {
    Tcl_AppendResult(interp, "Cannot find command ", credName, NULL);
    return TCL_ERROR;
  }

  if(cmdInfo.objProc != GssCredObjCmd)
  {
    Tcl_AppendResult(interp, "Command ", credName, " is not of type gsscred.", NULL);
    return TCL_ERROR;
  }

  *credPtr = (GssCred*) cmdInfo.clientData;

  if(credPtr == NULL)
  {
    Tcl_AppendResult(interp, "Failed to acquire delegated credentials.", NULL);
		return TCL_ERROR;
  }

  if((*credPtr)->gssCredBuf.value == NULL)
  {
    Tcl_AppendResult(interp, "Failed to acquire delegated credentials.", NULL);
		return TCL_ERROR;
  }

  return TCL_OK;
}

/* ----------------------------------------------------------------- */

static int
GssGetOptionProc(ClientData instanceData, Tcl_Interp *interp, CONST char *optionName, Tcl_DString *dstrPtr)
{
  OM_uint32 majorStatus, minorStatus;

  char cmdName[256];
  Tcl_CmdInfo cmdInfo;
  int cmdCounter;

  GssState *statePtr = (GssState *) instanceData;
  GssCred *credPtr;

  if(optionName == NULL)
  {
    Tcl_DStringAppendElement(dstrPtr, "-gssname");
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssNameBuf.value);

    Tcl_DStringAppendElement(dstrPtr, "-gssuser");
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssUser);

    if(statePtr->gssCredFileName.value != NULL)
    {
      Tcl_DStringAppendElement(dstrPtr, "-gssproxy");
      Tcl_DStringAppendElement(dstrPtr, statePtr->gssCredFileName.value + statePtr->gssCredFileNamePos);
    }

    if(statePtr->parentGetOptionProc != NULL)
    {
      return (*statePtr->parentGetOptionProc)(statePtr->parentInstData, interp, optionName, dstrPtr);
    }
    else
    {
      return TCL_OK;
    }
  }
  else if(strcmp(optionName, "-gssname") == 0)
  {
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssNameBuf.value);
    return TCL_OK;
  }
  else if(strcmp(optionName, "-gssuser") == 0)
  {
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssUser);
    return TCL_OK;
  }
  else if(strcmp(optionName, "-gssproxy") == 0)
  {
    if(statePtr->gssCredProxy != GSS_C_NO_CREDENTIAL &&
       statePtr->gssCredFileName.value == NULL)
    {

      majorStatus = gss_export_cred(&minorStatus,
                                     statePtr->gssCredProxy,
                                     NULL, 1,
                                     &statePtr->gssCredFileName);

      if (majorStatus == GSS_S_COMPLETE)
      {
        statePtr->gssCredFileNamePos = 0;
        if(statePtr->gssCredFileName.length > 16)
        {
          if(strncmp(statePtr->gssCredFileName.value,
                     "X509_USER_PROXY=", 16) == 0)
          {
            statePtr->gssCredFileNamePos = 16;
          }
        }
      }
      else
      {
        globus_gss_assist_display_status(
          stderr, "Failed to export credentials: ",
          majorStatus, minorStatus, 0);
      }
    }

    if(statePtr->gssCredFileName.value != NULL)
    {
      Tcl_DStringAppendElement(dstrPtr, statePtr->gssCredFileName.value + statePtr->gssCredFileNamePos);
      return TCL_OK;
    }
    else
    {
      Tcl_AppendResult(interp, "Failed to export credentials", NULL);
      return TCL_ERROR;
    }
  }
  else if(strcmp(optionName, "-gssexport") == 0)
  {
    if(statePtr->gssCredProxy != GSS_C_NO_CREDENTIAL)
    {

      credPtr = (GssCred *) ckalloc((unsigned int) sizeof(GssCred));
      memset(credPtr, 0, sizeof(GssCred));

      credPtr->gssCredBuf.length = 0;
      credPtr->gssCredBuf.value = NULL;

      majorStatus = gss_export_cred(&minorStatus,
                                     statePtr->gssCredProxy,
                                     NULL, 0,
                                     &credPtr->gssCredBuf);

      if (majorStatus == GSS_S_COMPLETE)
      {
        cmdCounter = 0;
        do {
          sprintf(cmdName, "gss::cred_%s_%d", Tcl_GetChannelName(statePtr->channel), cmdCounter);
          cmdCounter++;
        } while(Tcl_GetCommandInfo(interp, cmdName, &cmdInfo));
        credPtr->token = Tcl_CreateObjCommand(interp, cmdName, GssCredObjCmd,
          (ClientData) credPtr, GssCredDestroy);
        Tcl_DStringAppendElement(dstrPtr, cmdName);
        return TCL_OK;
      }
      else
      {
        globus_gss_assist_display_status(
          stderr, "Failed to export credentials: ",
          majorStatus, minorStatus, 0);
        Tcl_AppendResult(interp, "Failed to export credentials", NULL);
        return TCL_ERROR;
      }
    }
  }
  else if(statePtr->parentGetOptionProc != NULL)
  {
    return (*statePtr->parentGetOptionProc)(statePtr->parentInstData, interp, optionName, dstrPtr);
  }

  return Tcl_BadChannelOption(interp, optionName, "gssname");
}

/* ----------------------------------------------------------------- */

static void
GssChannelHandlerTimer(ClientData instanceData)
{
  GssState *statePtr = (GssState *) instanceData;
  int mask = 0;

  statePtr->timer = (Tcl_TimerToken) NULL;

  if(0)
  {
    mask |= TCL_WRITABLE;
  }

  if(0)
  {
    mask |= TCL_READABLE;
  }

  Tcl_NotifyChannel(statePtr->channel, mask);
}

/* ----------------------------------------------------------------- */

static void
GssWatchProc(ClientData instanceData,	int mask)
{
  GssState *statePtr = (GssState *) instanceData;

  if(0) printf("---> GssWatchProc(0x%x)\n", mask);

	statePtr->extWatchMask = mask;

	if(!(statePtr->flags & GSS_TCL_HANDSHAKE))
	{
    (*statePtr->parentWatchProc) (statePtr->parentInstData, statePtr->intWatchMask | statePtr->extWatchMask);
  }

 /*
  * Management of the internal timer.
  */

	if(statePtr->timer != (Tcl_TimerToken) NULL)
  {
    Tcl_DeleteTimerHandler(statePtr->timer);
    statePtr->timer = (Tcl_TimerToken) NULL;
	}

	if((mask & TCL_READABLE) && Tcl_InputBuffered(statePtr->channel) > 0)
  {
   /*
    * There is interest in readable events and we actually have
    * data waiting, so generate a timer to flush that.
    */
	  statePtr->timer = Tcl_CreateTimerHandler(GSS_TCL_DELAY, GssChannelHandlerTimer, (ClientData) statePtr);
	}
}

/* ----------------------------------------------------------------- */

static int
GssHandshake(GssState *statePtr)
{
  OM_uint32 majorStatus, minorStatus;
  globus_result_t result;

  if(0) printf("---> GssHandshake\n");

  if(statePtr->flags & GSS_TCL_SERVER)
  {
    majorStatus
      = gss_accept_sec_context(&minorStatus,               /* (out) minor status */
                               &statePtr->gssContext,      /* (in) security context */
                               statePtr->gssCredential,    /* (in) cred handle */
                               &statePtr->readRawBuf,      /* (in) input token */
                               GSS_C_NO_CHANNEL_BINDINGS,  /* (in) */
                               &statePtr->gssName,         /* (out) name of initiator */
                               NULL,                       /* (out) mechanisms */
                               &statePtr->writeRawBuf,     /* (out) output token */
                               &statePtr->gssFlags,        /* (out) return flags
                                                                    bit-mask of:
                                                                    GSS_C_DELEG_FLAG
                                                                    GSS_C_MUTUAL_FLAG
                                                                    GSS_C_REPLAY_FLAG
                                                                    GSS_C_SEQUENCE_FLAG
                                                                    GSS_C_CONF_FLAG
                                                                    GSS_C_INTEG_FLAG
                                                                    GSS_C_ANON_FLAG
                                                                    GSS_C_PROT_READY_FLAG
                                                                    GSS_C_TRANS_FLAG */
                               &statePtr->gssTime,         /* (out) time ctx is valid */
                               &statePtr->gssCredProxy); /* (out) delegated cred */

  }
  else
  {
    majorStatus
      = gss_init_sec_context(&minorStatus,            /* (out) minor status */
                             statePtr->gssCredential, /* (in) cred handle */
                             &statePtr->gssContext,   /* (in) sec context */
                             statePtr->gssName,   /* (in) name of target */
                             GSS_C_NO_OID,        /* (in) mech type */
                             GSS_C_MUTUAL_FLAG |
                             GSS_C_GLOBUS_LIMITED_DELEG_PROXY_FLAG |
                             GSS_C_DELEG_FLAG,    /* (in) request flags
                                                          bit-mask of:
                                                          GSS_C_DELEG_FLAG
                                                          GSS_C_DELEG_FLAG
                                                          GSS_C_REPLAY_FLAG
                                                          GSS_C_SEQUENCE_FLAG
                                                          GSS_C_CONF_FLAG
                                                          GSS_C_INTEG_FLAG
                                                          GSS_C_ANON_FLAG */
                             0,                   /* (in) time ctx is valid
                                                          0 = default time */
                             GSS_C_NO_CHANNEL_BINDINGS, /* chan binding */
                             &statePtr->readRawBuf,  /* (in) input token */
                             NULL,                   /* (out) actual mech */
                             &statePtr->writeRawBuf, /* (out) output token */
                             &statePtr->gssFlags,    /* (out) return flags
                                                              bit-mask of:
                                                              GSS_C_DELEG_FLAG
                                                              GSS_C_MUTUAL_FLAG
                                                              GSS_C_REPLAY_FLAG
                                                              GSS_C_SEQUENCE_FLAG
                                                              GSS_C_CONF_FLAG
                                                              GSS_C_INTEG_FLAG
                                                              GSS_C_ANON_FLAG
                                                              GSS_C_PROT_READY_FLAG
                                                              GSS_C_TRANS_FLAG */
                             &statePtr->gssTime);    /* (out) time ctx is valid */
  }

  statePtr->readRawBuf.length = 5;
  statePtr->readRawBufPos = 0;
  statePtr->flags |= GSS_TCL_READHEADER;

  if(statePtr->writeRawBuf.length > 0)
  {
    statePtr->intWatchMask |= TCL_WRITABLE;
  	(*statePtr->parentWatchProc) (statePtr->parentInstData, statePtr->intWatchMask);
  }

  if(!(majorStatus & GSS_S_CONTINUE_NEEDED))
  {
    if(majorStatus == GSS_S_COMPLETE)
    {
      majorStatus = gss_display_name(&minorStatus,
                                     statePtr->gssName,
                                     &statePtr->gssNameBuf,
                                     NULL);
      statePtr->flags &= ~(GSS_TCL_HANDSHAKE);
      (*statePtr->parentWatchProc) (statePtr->parentInstData, statePtr->intWatchMask | statePtr->extWatchMask);

      if(statePtr->flags & GSS_TCL_SERVER)
      {
        result = globus_gss_assist_gridmap(statePtr->gssNameBuf.value, &statePtr->gssUser);
        result = globus_gss_assist_userok(statePtr->gssNameBuf.value, statePtr->gssUser);
/*
        statePtr->gssUser[0] = '\0';
        result = globus_gss_assist_map_and_authorize(statePtr->gssContext,
                                                     "srm", NULL,
                                                     statePtr->gssUser, 256);
        printf("---> user = %s, dn = %s\n", statePtr->gssUser, statePtr->gssNameBuf.value);
*/
      }
    }
    else
    {
      statePtr->flags |= GSS_TCL_EOF;
      statePtr->errorCode = 0;

      globus_gss_assist_display_status(
        stderr, "Failed to establish security context: ",
        majorStatus, minorStatus, 0);
    }
  }

  if(0) printf("---> GssHandshake(0x%x)  %d   %d\n", majorStatus, statePtr->readRawBuf.length, statePtr->writeRawBuf.length);
  return 0;
}

/* ----------------------------------------------------------------- */

static int
GssReadRaw(GssState *statePtr, char *buffer, int bytesToRead)
{
  int bytesRead;

  bytesRead = Tcl_ReadRaw(statePtr->parent, buffer, bytesToRead);

  if(0) printf("---> GssReadRaw -> %d -> %d\n", bytesToRead, bytesRead);

  if(bytesRead == 0)
  {
    statePtr->flags |= GSS_TCL_EOF;
    statePtr->errorCode = 0;
  }
  else if(bytesRead < 0)
  {
    statePtr->flags |= GSS_TCL_INPUTERROR;
    statePtr->errorCode = Tcl_GetErrno();
  }
  else
  {
    statePtr->readRawBufPos += bytesRead;
  }

  return bytesRead;
}

/* ----------------------------------------------------------------- */

static int
GssUnwrapToken(GssState *statePtr)
{
  OM_uint32 majorStatus, minorStatus;

  if(!(statePtr->flags & GSS_TCL_READHEADER) &&
     (statePtr->readRawBufPos == statePtr->readRawBuf.length) &&
     (statePtr->readOutBuf.length == 0))
  {
    majorStatus = gss_unwrap(&minorStatus,
                             statePtr->gssContext,
                             &statePtr->readRawBuf,
                             &statePtr->readOutBuf,
                             NULL, GSS_C_QOP_DEFAULT);

    if(majorStatus == GSS_S_COMPLETE)
    {
      statePtr->readRawBuf.length = 5;
      statePtr->readRawBufPos = 0;
      statePtr->flags |= GSS_TCL_READHEADER;
    }
    else
    {
      statePtr->flags |= GSS_TCL_EOF;
      statePtr->errorCode = 0;

      globus_gss_assist_display_status(
        stderr, "Failed to unwrap buffer: ",
        majorStatus, minorStatus, 0);
    }
  }
  if(0) printf("---> GssUnwrapToken %d -> %d\n", statePtr->readRawBuf.length, statePtr->readOutBuf.length);

}

/* ----------------------------------------------------------------- */

static int
GssReadToken(GssState *statePtr)
{
  int bytesToRead, bytesRead;
  unsigned char *buffer;
  unsigned char *header;

  if(0) printf("---> GssReadToken -> %d\n", statePtr->readRawBufPos);

  bytesRead = -1;

  if(statePtr->readRawBuf.length > statePtr->readRawBufSize)
  {
    statePtr->flags |= GSS_TCL_EOF;
    statePtr->errorCode = 0;
  }
  else if(statePtr->readRawBuf.length > 0)
  {
    if(statePtr->readRawBufPos < statePtr->readRawBuf.length)
    {
      buffer = statePtr->readRawBuf.value + statePtr->readRawBufPos;
      bytesToRead = statePtr->readRawBuf.length - statePtr->readRawBufPos;

      bytesRead = GssReadRaw(statePtr, buffer, bytesToRead);
    }

    if(statePtr->readRawBufPos == statePtr->readRawBuf.length)
    {
      if(statePtr->flags & GSS_TCL_READHEADER)
      {
        if(statePtr->readRawBufPos == 5)
        {
          header = statePtr->readRawBuf.value;
          if(
              (
                header[0] >= 20 && header[0] <= 26 &&
                (
                  (header[1] == 3 && (header[2] == 0 || header[2] == 1)) ||
                  (header[1] == 2 && (header[2] == 0))
                )
              ) || ((header[0] & 0x80) && (header[2] == 1))
            )
          {
            if(header[0] & 0x80)
            {
              statePtr->readRawBuf.length =
                ((((OM_uint32) header[0] & 0x7f) << 8) | ((OM_uint32) header[1])) + 2;
            }
            else
            {
              statePtr->readRawBuf.length =
                ((((OM_uint32) header[3]) << 8) | ((OM_uint32) header[4])) + 5;
            }

            if(header[0] == 26 )
            {
              statePtr->readRawBuf.length += 12;
            }
            else
            {
              statePtr->flags &= ~(GSS_TCL_READHEADER);
            }
          }
          else
          {
            statePtr->readRawBuf.length = ntohl(*((uint32_t *) header));
            memcpy(statePtr->readRawBuf.value, header + 4, 1);
            statePtr->readRawBufPos = 1;
            statePtr->flags &= ~(GSS_TCL_READHEADER);
          }

          if(statePtr->readRawBuf.length < 1)
          {
            statePtr->readRawBuf.length = 5;
            statePtr->readRawBufPos = 0;
            statePtr->flags |= GSS_TCL_READHEADER;
          }
        }
        else
        {
          header = statePtr->readRawBuf.value + statePtr->readRawBuf.length - 4;
          statePtr->readRawBuf.length += ntohl(*((uint32_t *) header));
          statePtr->flags &= ~(GSS_TCL_READHEADER);
        }
      }
      else if(statePtr->flags & GSS_TCL_HANDSHAKE)
      {
        GssHandshake(statePtr);
      }
      else
      {
        GssUnwrapToken(statePtr);
      }
    }
  }

  if(0) printf("---> GssReadToken(%d) -> %d\n", bytesToRead, bytesRead);
  return bytesRead;
}

/* ----------------------------------------------------------------- */

static int
GssWriteRaw(GssState *statePtr, char *buffer, int bytesToWrite)
{
  int bytesWritten;

  bytesWritten = Tcl_WriteRaw(statePtr->parent, buffer, bytesToWrite);

  if(0) printf("---> GssWriteRaw -> %d\n", bytesWritten);

  if(bytesWritten < 0)
  {
    statePtr->flags |= GSS_TCL_OUTPUTERROR;
    statePtr->errorCode = Tcl_GetErrno();
  }
  else
  {
    statePtr->writeRawBufPos += bytesWritten;
  }

  return bytesWritten;
}

/* ----------------------------------------------------------------- */

static int
GssWrapToken(GssState *statePtr)
{
  OM_uint32 majorStatus, minorStatus;

  if((statePtr->writeInBuf.length > 0) &&
     (statePtr->writeRawBuf.length == 0))
  {
    majorStatus = gss_wrap(&minorStatus,
                           statePtr->gssContext,
                           0, GSS_C_QOP_DEFAULT,
                           &statePtr->writeInBuf,
                           NULL,
                           &statePtr->writeRawBuf);
    if(majorStatus == GSS_S_COMPLETE)
    {
      statePtr->writeInBuf.length = 0;
    }
    else
    {
      statePtr->flags |= GSS_TCL_EOF;
      statePtr->errorCode = 0;

      globus_gss_assist_display_status(
        stderr, "Failed to wrap buffer: ",
        majorStatus, minorStatus, 0);
    }
  }
  if(0) printf("---> GssWrapToken %d -> %d\n", statePtr->writeInBuf.length, statePtr->writeRawBuf.length);
}

/* ----------------------------------------------------------------- */

static int
GssWriteToken(GssState *statePtr)
{
  int bytesToWrite, bytesWritten;
  char *buffer;
  char *header;

  OM_uint32 majorStatus, minorStatus;

  if(0) printf("---> GssWriteToken -> %d\n", statePtr->writeRawBufPos);

  bytesWritten = -1;

  if(!(statePtr->flags & GSS_TCL_HANDSHAKE) &&
     (statePtr->writeRawBuf.length == 0))
  {
    GssWrapToken(statePtr);
  }

  if(statePtr->writeRawBuf.length > 0)
  {
    if(statePtr->writeRawBufPos < 4)
    {
      header = statePtr->writeRawBuf.value;
      if(
          statePtr->writeRawBuf.length > 5 &&
          header[0] <= 26 && header[0] >= 20 &&
          (
            (header[1] == 3 && (header[2] == 0 || header[2] == 1)) ||
            (header[1] == 2 && (header[2] == 0))
          )
        )
      {
        statePtr->writeRawBufPos += 4;
        bytesWritten = 4;
      }
      else
      {
        *((uint32_t *) statePtr->writeTokenSizeBuf) = htonl(statePtr->writeRawBuf.length);

        buffer = statePtr->writeTokenSizeBuf + statePtr->writeRawBufPos;
        bytesToWrite = 4 - statePtr->writeRawBufPos;

        bytesWritten = GssWriteRaw(statePtr, buffer, bytesToWrite);
      }
    }

    if(statePtr->writeRawBufPos > 3 && statePtr->writeRawBufPos < statePtr->writeRawBuf.length + 4)
    {
      buffer = statePtr->writeRawBuf.value + statePtr->writeRawBufPos - 4;
      bytesToWrite = 4 + statePtr->writeRawBuf.length - statePtr->writeRawBufPos;

      bytesWritten = GssWriteRaw(statePtr, buffer, bytesToWrite);
    }

    if(statePtr->writeRawBufPos == statePtr->writeRawBuf.length + 4)
    {
      majorStatus = gss_release_buffer(&minorStatus, &statePtr->writeRawBuf);
      statePtr->writeRawBufPos = 0;
      statePtr->writeRawBuf.length = 0;
      statePtr->writeRawBuf.value = NULL;
    }

    if(statePtr->writeRawBuf.length == 0 && statePtr->writeInBuf.length == 0)
    {
      statePtr->intWatchMask &= ~(TCL_WRITABLE);
      if(statePtr->flags & GSS_TCL_HANDSHAKE)
      {
  	    (*statePtr->parentWatchProc) (statePtr->parentInstData, statePtr->intWatchMask);
      }
      else
      {
  	    (*statePtr->parentWatchProc) (statePtr->parentInstData, statePtr->intWatchMask | statePtr->extWatchMask);
      }
    }
  }

  if(bytesWritten < 0)
  {
    statePtr->flags |= GSS_TCL_OUTPUTERROR;
    statePtr->errorCode = EAGAIN;
  }

  if(0) printf("---> GssWriteToken(%d) -> %d [0x%x]\n", bytesToWrite, bytesWritten, statePtr->intWatchMask);
  return bytesWritten;
}

/* ----------------------------------------------------------------- */

static int
GssNotifyProc(ClientData instanceData, int mask)
{
  GssState *statePtr = (GssState *) instanceData;

  if(0) printf("---> GssNotifyProc(0x%x)\n", mask);

  if(statePtr->timer != (Tcl_TimerToken) NULL)
  {

   /*
    * Delete an existing timer. It was not fired, yet we are
    * here, so the channel below generated such an event and we
    * don't have to. The renewal of the interest after the
    * execution of channel handlers will eventually cause us to
    * recreate the timer (in WatchProc).
    */

    Tcl_DeleteTimerHandler(statePtr->timer);
    statePtr->timer = (Tcl_TimerToken) NULL;
  }

  if(mask & TCL_READABLE)
  {
    if(!(statePtr->extWatchMask & TCL_READABLE) ||
       (statePtr->flags & GSS_TCL_HANDSHAKE))
    {
      mask &= ~(TCL_READABLE);
    }

    if(!(statePtr->flags & GSS_TCL_EOF) &&
       (statePtr->intWatchMask & TCL_READABLE))
    {
      GssReadToken(statePtr);
    }

    if(statePtr->readOutBuf.length == 0)
    {
      mask &= ~(TCL_READABLE);
    }

    if((statePtr->flags & GSS_TCL_EOF) ||
       (statePtr->flags & GSS_TCL_INPUTERROR && statePtr->errorCode != EAGAIN))
    {
      statePtr->flags &= ~(GSS_TCL_HANDSHAKE);
      mask |= TCL_READABLE;
    }
  }
  else if(mask & TCL_WRITABLE)
  {
    if(!(statePtr->extWatchMask & TCL_WRITABLE) ||
       (statePtr->flags & GSS_TCL_HANDSHAKE))
    {
      mask &= ~(TCL_WRITABLE);
    }

    if(!(statePtr->flags & GSS_TCL_EOF) &&
       (statePtr->intWatchMask & TCL_WRITABLE))
    {
      GssWriteToken(statePtr);
    }

    if(statePtr->writeInBuf.length == statePtr->writeInBufSize)
    {
      mask &= ~(TCL_WRITABLE);
    }

    if((statePtr->flags & GSS_TCL_EOF) ||
       (statePtr->flags & GSS_TCL_OUTPUTERROR && statePtr->errorCode != EAGAIN))
    {
      statePtr->flags &= ~(GSS_TCL_HANDSHAKE);
      mask |= TCL_WRITABLE;
    }
  }

  if(0) printf("---> Exiting GssNotifyProc(0x%x)\n", mask);

  return mask;
}

/* ----------------------------------------------------------------- */

static int
GssImportObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
  Tcl_Channel chan;

  GssState *statePtr;

  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc gssNameBuf;

  Tcl_DString peerName;
  Tcl_Obj *peerNameObj;
  char *peerNameStr;

  GssCred *credPtr;
  char *credName;

  int idx, rc;
  int server;             /* is connection incoming or outgoing? */

  if(objc < 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "channel ?options?");
    return TCL_ERROR;
  }

  chan = Tcl_GetChannel(interp, Tcl_GetStringFromObj(objv[1], NULL), NULL);
  if(chan == (Tcl_Channel) NULL)
  {
    return TCL_ERROR;
  }
  chan = Tcl_GetTopChannel(chan);

  server = 0;
  credName = NULL;
  credPtr = NULL;

  for(idx = 2; idx < objc; ++idx)
  {
    char *option = Tcl_GetString(objv[idx]);

    if(option[0] != '-') break;

    if(strcmp(option, "-server") == 0)
    {
      if(++idx >= objc)
      {
        Tcl_WrongNumArgs(interp, 1, objv, "channel -server boolean");
        return TCL_ERROR;
      }

      if (Tcl_GetBooleanFromObj(interp, objv[idx], &server) != TCL_OK)
      {
        return TCL_ERROR;
      }

      continue;
    }

    if(strcmp(option, "-gssimport") == 0)
    {
      if(++idx >= objc)
      {
        Tcl_WrongNumArgs(interp, 1, objv, "channel -gssimport cred");
        return TCL_ERROR;
      }

      credName = Tcl_GetString(objv[idx]);

      continue;
    }

    Tcl_AppendResult(interp, "bad option \"", option,
      "\": should be server, gssimport", (char *) NULL);

    return TCL_ERROR;
  }

  if(credName != NULL)
  {
    rc = GssCredGet(interp, credName, &credPtr);
    if(rc != TCL_OK ) return rc;
  }


  statePtr = (GssState *) ckalloc((unsigned int) sizeof(GssState));
  memset(statePtr, 0, sizeof(GssState));

 /*
  * We need to make sure that the channel works in binary (for the
  * encryption not to get goofed up).
  */
  Tcl_SetChannelOption(interp, chan, "-translation", "binary");

  statePtr->interp = interp;

  statePtr->channel = Tcl_StackChannel(interp, &ChannelType,
                                       (ClientData) statePtr,
                                       (TCL_READABLE | TCL_WRITABLE | TCL_EXCEPTION), chan);

  if(statePtr->channel == (Tcl_Channel) NULL)
  {
    GssClean(statePtr);
    Tcl_EventuallyFree((ClientData) statePtr, TCL_DYNAMIC);
    return TCL_ERROR;
  }

  statePtr->parent = Tcl_GetStackedChannel(statePtr->channel);

  statePtr->parentGetOptionProc = Tcl_ChannelGetOptionProc(Tcl_GetChannelType(statePtr->parent));
  statePtr->parentBlockModeProc = Tcl_ChannelBlockModeProc(Tcl_GetChannelType(statePtr->parent));
  statePtr->parentWatchProc = Tcl_ChannelWatchProc(Tcl_GetChannelType(statePtr->parent));
  statePtr->parentInstData = Tcl_GetChannelInstanceData(statePtr->parent);

  (*statePtr->parentBlockModeProc) (statePtr->parentInstData, TCL_MODE_NONBLOCKING);

  statePtr->intWatchMask |= TCL_READABLE;
	(*statePtr->parentWatchProc) (statePtr->parentInstData, statePtr->intWatchMask);

  statePtr->writeInBufSize = 32768;
  statePtr->writeInBuf.length = 0;
  statePtr->writeInBuf.value = ckalloc(statePtr->writeInBufSize);

  statePtr->readRawBufSize = 32768;
  statePtr->readRawBuf.length = 5;
  statePtr->readRawBuf.value = ckalloc(statePtr->readRawBufSize);

  memset(statePtr->readRawBuf.value, 0, 5);
  statePtr->flags |= GSS_TCL_READHEADER;

  statePtr->flags |= GSS_TCL_BLOCKING;

  statePtr->gssName = GSS_C_NO_NAME;
  statePtr->gssContext = GSS_C_NO_CONTEXT;
  statePtr->gssCredential = GSS_C_NO_CREDENTIAL;
  statePtr->gssCredProxy = GSS_C_NO_CREDENTIAL;

  statePtr->gssNameBuf.length = 0;
  statePtr->gssNameBuf.value = NULL;
  statePtr->gssCredFileName.length = 0;
  statePtr->gssCredFileName.value = NULL;
  statePtr->gssCredFileNamePos = 0;

  if(credPtr == NULL)
  {
    majorStatus = gss_acquire_cred(&minorStatus,     /* (out) minor status */
                                   GSS_C_NO_NAME,    /* (in) desired name */
                                   GSS_C_INDEFINITE, /* (in) desired time valid */
                                   GSS_C_NO_OID_SET, /* (in) desired mechs */
                                   GSS_C_BOTH,       /* (in) cred usage
                                                             GSS_C_BOTH
                                                             GSS_C_INITIATE
                                                             GSS_C_ACCEPT */
                                   &statePtr->gssCredential, /* (out) cred handle */
                                   NULL,                     /* (out) actual mechs */
                                   NULL);                    /* (out) actual time valid */

    if(majorStatus != GSS_S_COMPLETE)
    {
      globus_gss_assist_display_status(
        stderr, "Failed to acquire credentials: ",
        majorStatus, minorStatus, 0);

      GssClean(statePtr);
      Tcl_EventuallyFree((ClientData) statePtr, TCL_DYNAMIC);
      return TCL_ERROR;
    }
  }
  else
  {
    majorStatus = gss_import_cred(&minorStatus,             /* (out) minor status */
                                  &statePtr->gssCredential, /* (out) cred handle */
                                  GSS_C_NO_OID,             /* (in) desired mechs */
                                  1,                        /* (in) option_req used by gss_export_cred */
                                  &credPtr->gssCredBuf,     /* (in) buffer produced by gss_export_cred */
                                  GSS_C_INDEFINITE,         /* (in) desired time valid */
                                  NULL);                    /* (out) actual time valid */

    if (majorStatus == GSS_S_COMPLETE)
    {
      globus_gss_assist_display_status(
        stderr, "Failed to import credentials: ",
        majorStatus, minorStatus, 0);

      GssClean((ClientData) statePtr);
      return TCL_ERROR;
    }
  }

  statePtr->flags |= GSS_TCL_HANDSHAKE;

  if(server)
  {
    statePtr->flags |= GSS_TCL_SERVER;
  }
  else
  {
    Tcl_DStringInit(&peerName);

    Tcl_GetChannelOption(interp, chan, "-peername", &peerName);
    peerNameObj = Tcl_NewStringObj(Tcl_DStringValue(&peerName), -1);
    Tcl_ListObjIndex(interp, peerNameObj, 1, &peerNameObj);
    peerNameStr = Tcl_GetStringFromObj(peerNameObj, 0);

    Tcl_DStringFree(&peerName);

    /* extract the name associated with the creds */
    gssNameBuf.value = peerNameStr;
    gssNameBuf.length = strlen(peerNameStr) + 1;
    majorStatus = gss_import_name(&minorStatus,
                                  &gssNameBuf,
                                  GSS_C_NT_HOSTBASED_SERVICE,
                                  &statePtr->gssName);

/*
    majorStatus = gss_inquire_cred(&minorStatus,
                                   statePtr->gssCredential,
                                   &statePtr->gssName,
                                   NULL, NULL, NULL);
*/
    if(majorStatus != GSS_S_COMPLETE)
    {
      globus_gss_assist_display_status(
        stderr, "Failed to determine server name: ",
        majorStatus, minorStatus, 0);

      GssClean(statePtr);
      Tcl_EventuallyFree((ClientData) statePtr, TCL_DYNAMIC);
      return TCL_ERROR;
    }

    GssHandshake(statePtr);
  }

  Tcl_SetResult(interp,
                (char *) Tcl_GetChannelName(statePtr->channel),
                TCL_VOLATILE);
  return TCL_OK;
}

/* ----------------------------------------------------------------- */

int
Gss_Init(Tcl_Interp *interp)
{
  Tcl_CreateObjCommand(interp, "gss::import", GssImportObjCmd,
    (ClientData) 0, (Tcl_CmdDeleteProc *) NULL);

  return Tcl_PkgProvide(interp, "gss::socket", "0.1");
}

/* ----------------------------------------------------------------- */

int
Gss_SafeInit(Tcl_Interp *interp)
{
  return Gss_Init(interp);
}
