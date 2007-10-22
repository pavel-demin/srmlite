#include <tcl.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>

#include <gssapi.h>
#include <globus_gss_assist.h>

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

#define XX 100

static unsigned char GsiftpBase64Pad = '=';

static unsigned char GsiftpBase64CharSet[64] =
"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static unsigned char GsiftpBase64CharIndex[256] = {
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,62, XX,XX,XX,63,
    52,53,54,55, 56,57,58,59, 60,61,XX,XX, XX,XX,XX,XX,
    XX, 0, 1, 2,  3, 4, 5, 6,  7, 8, 9,10, 11,12,13,14,
    15,16,17,18, 19,20,21,22, 23,24,25,XX, XX,XX,XX,XX,
    XX,26,27,28, 29,30,31,32, 33,34,35,36, 37,38,39,40,
    41,42,43,44, 45,46,47,48, 49,50,51,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
    XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX, XX,XX,XX,XX,
};

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
  gss_cred_id_t gssDelegProxy;
  gss_buffer_desc gssDelegProxyFileName;
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

typedef struct GsiftpContext {
  Tcl_Command token;
  Tcl_Channel channel;
  Tcl_Channel delegate;

  gss_cred_id_t gssCredential;
  gss_cred_id_t gssDelegProxy;
  gss_ctx_id_t gssContext;
  gss_name_t gssName;
  gss_buffer_desc gssNameBuf;
  OM_uint32 gssFlags;
  OM_uint32 gssTime;
} GsiftpContext;

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

  if(statePtr->gssDelegProxy != GSS_C_NO_CREDENTIAL)
  {
    majorStatus = gss_release_cred(&minorStatus,
                                   &statePtr->gssDelegProxy);
  }

  if(statePtr->gssDelegProxyFileName.value != NULL)
  {
    majorStatus = gss_release_buffer(&minorStatus, &statePtr->gssDelegProxyFileName);
    statePtr->gssDelegProxyFileName.value = NULL;
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

static int
GssGetOptionProc(ClientData instanceData,	Tcl_Interp *interp, CONST char *optionName,	Tcl_DString *dstrPtr)
{
  GssState *statePtr = (GssState *) instanceData;

  if(optionName == NULL)
  {
    Tcl_DStringAppendElement(dstrPtr, "-gssname");
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssNameBuf.value);

    Tcl_DStringAppendElement(dstrPtr, "-gssuser");
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssUser);

    Tcl_DStringAppendElement(dstrPtr, "-gssproxy");
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssDelegProxyFileName.value);

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
    Tcl_DStringAppendElement(dstrPtr, statePtr->gssDelegProxyFileName.value);
    return TCL_OK;
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
                               &statePtr->gssDelegProxy); /* (out) delegated cred */

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
        if(statePtr->gssDelegProxy != GSS_C_NO_CREDENTIAL)
        {

          majorStatus = gss_export_cred(&minorStatus,
                                         statePtr->gssDelegProxy,
                                         NULL, 1,
                                         &statePtr->gssDelegProxyFileName);
          
          if (majorStatus == GSS_S_COMPLETE)
          {
            printf("---> proxy = %s\n", statePtr->gssDelegProxyFileName.value);
          }
          else
          {
            statePtr->flags |= GSS_TCL_EOF;
            statePtr->errorCode = 0;

            globus_gss_assist_display_status(
              stderr, "Failed to export credentials: ",
              majorStatus, minorStatus, 0);
          }
        }

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
  Tcl_Channel chan, delegate;

  ClientData delegateInstData;
  Tcl_ChannelType *delegateChannelTypePtr;

  GssState *delegateStatePtr;
  GssState *statePtr;

  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc gssNameBuf;

  Tcl_DString peerName;
  Tcl_Obj *peerNameObj;
  char *peerNameStr;
  char *channelName;

  int idx;
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
  channelName = NULL;
  delegate = (Tcl_Channel) NULL;

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

    if(strcmp(option, "-delegate") == 0)
    {
      if(++idx >= objc)
      {
        Tcl_WrongNumArgs(interp, 1, objv, "channel -delegate channel");
        return TCL_ERROR;
      }

      channelName = Tcl_GetString(objv[idx]);

      continue;
    }

    Tcl_AppendResult(interp, "bad option \"", option,
      "\": should be server, delegate", (char *) NULL);

    return TCL_ERROR;
  }

  if(channelName != NULL)
  {
    delegate = Tcl_GetChannel(interp, channelName, NULL);
    if(delegate == (Tcl_Channel) NULL)
    {
      Tcl_AppendResult(interp, "Cannot find channel ", channelName, NULL);
      return TCL_ERROR;
    }

    delegateChannelTypePtr = Tcl_GetChannelType(delegate);

    if(delegateChannelTypePtr == NULL)
    {
      Tcl_AppendResult(interp, "Cannot define type of channel ", channelName, NULL);
      return TCL_ERROR;
    }

    if(strcmp(delegateChannelTypePtr->typeName, "gss"))
    {
      Tcl_AppendResult(interp, "Channel ", channelName, " is not of type gss.", NULL);
      return TCL_ERROR;
    }

    delegateInstData = Tcl_GetChannelInstanceData(delegate);
    delegateStatePtr = (GssState *) delegateInstData;

    if(delegateStatePtr->gssDelegProxy == GSS_C_NO_CREDENTIAL)
    {
      Tcl_AppendResult(interp, "Failed to acquire delegated credentials.", NULL);
  		return TCL_ERROR;
    }
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
  statePtr->gssDelegProxy = GSS_C_NO_CREDENTIAL;

  if(delegate == (Tcl_Channel) NULL)
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
    statePtr->gssCredential = delegateStatePtr->gssDelegProxy;
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
/* ----------------------------------------------------------------- */

static int GsiftpBase64Encode(CONST unsigned char *inputBuffer,
                              int inputBufferSize,
                              Tcl_Obj *outputObject)
{
  int i, j;
  unsigned char character;
  unsigned char buffer[4];

  for(i = 0, j = 0; i < inputBufferSize; ++i)
  {
    switch(i % 3)
    {
      case 0:
        buffer[j++] = GsiftpBase64CharSet[inputBuffer[i] >> 2];
        character = (inputBuffer[i] & 3) << 4;
        break;
      case 1:
        buffer[j++] = GsiftpBase64CharSet[character | inputBuffer[i] >> 4];
        character = (inputBuffer[i] & 15) << 2;
        break;
      case 2:
        buffer[j++] = GsiftpBase64CharSet[character | inputBuffer[i] >> 6];
        buffer[j++] = GsiftpBase64CharSet[inputBuffer[i] & 63];
        character = 0; j = 0;
        Tcl_AppendToObj(outputObject, buffer, 4);
    }
  }

  if(i % 3)
  {
    buffer[j++] = GsiftpBase64CharSet[character];
  }

  switch(i % 3)
  {
    case 1:
      buffer[j++] = GsiftpBase64Pad;
    case 2:
      buffer[j++] = GsiftpBase64Pad;
      Tcl_AppendToObj(outputObject, buffer, 4);
  }

  return j;
}

/* ----------------------------------------------------------------- */

static int GsiftpBase64Decode(CONST unsigned char *inputBuffer,
                              int inputBufferSize,
                              Tcl_Obj *outputObject)
{
  int i, j;
  unsigned char index;
  unsigned char buffer[3];

  for(i = 0, j = 0; inputBuffer[i] != GsiftpBase64Pad && i < inputBufferSize; ++i)
  {
    index = GsiftpBase64CharIndex[inputBuffer[i]];

    if(index == XX) return -1;

    switch(i & 3)
    {
      case 0:
        buffer[j] = index << 2;
        break;
      case 1:
        buffer[j++] |= index >> 4;
        buffer[j] = (index & 15) << 4;
        break;
      case 2:
        buffer[j++] |= index >> 2;
        buffer[j] = (index & 3) << 6;
        break;
      case 3:
        buffer[j++] |= index; j = 0;
        Tcl_AppendToObj(outputObject, buffer, 3);
    }
  }

  if(j > 0)
  {
    Tcl_AppendToObj(outputObject, buffer, j);
  }

  switch(i & 3)
  {
    case 1:
      return -1;
    case 2:
      if(index & 15)
      {
        return -1;
      }
      if(memcmp(inputBuffer + i, "==", 2))
      {
        return -1;
      }
      break;
    case 3:
      if(index & 3)
      {
        return -1;
      }
      if(memcmp(inputBuffer + i, "=", 1))
      {
        return -1;
      }
  }

  return j;
}

/* ----------------------------------------------------------------- */

static void
GsiftpDestroy(ClientData clientData)
{
  OM_uint32 majorStatus, minorStatus;
  GsiftpContext *statePtr = (GsiftpContext *) clientData;

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

  ckfree((char *)statePtr);
}

/* ----------------------------------------------------------------- */

static int
GsiftpHandshakeObjCmd(GsiftpContext *statePtr, Tcl_Interp *interp, Tcl_Obj *CONST obj)
{
  OM_uint32 majorStatus, minorStatus;

  gss_buffer_desc bufferIn, bufferOut;

  char *data;
  int length, offset;

  Tcl_Obj *result;

  data = Tcl_GetStringFromObj(obj, &length);
  result = Tcl_NewObj();

  if(length > 0)
  {
    offset = 0;

    if(memcmp(data, "235 ADAT", 8) == 0 ||
       memcmp(data, "335 ADAT", 8) == 0)
    {
      offset = 9;
    }

    if(GsiftpBase64Decode(data + offset, length - offset, result) < 0)
    {
      Tcl_AppendResult(interp, "Corrupted base64 data", NULL);
      return TCL_ERROR;
    }

    data = Tcl_GetStringFromObj(result, &length);

    bufferIn.value = data;
    bufferIn.length = length;
  }
  else
  {
    bufferIn.value = NULL;
    bufferIn.length = 0;
  }

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
                           &bufferIn,              /* (in) input token */
                           NULL,                   /* (out) actual mech */
                           &bufferOut,             /* (out) output token */
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

  if(majorStatus & GSS_S_CONTINUE_NEEDED)
  {
    result = Tcl_NewStringObj("ADAT ", -1);

    GsiftpBase64Encode(bufferOut.value, bufferOut.length, result);

    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);

    Tcl_SetObjResult(interp, result);

  	return TCL_OK;
  }
  else
  {
    if(majorStatus == GSS_S_COMPLETE)
    {
      majorStatus = gss_display_name(&minorStatus,
                                     statePtr->gssName,
                                     &statePtr->gssNameBuf,
                                     NULL);

      result = Tcl_NewStringObj("ADAT ", -1);

      GsiftpBase64Encode(bufferOut.value, bufferOut.length, result);

      majorStatus = gss_release_buffer(&minorStatus, &bufferOut);

      Tcl_SetObjResult(interp, result);

      return TCL_OK;
    }
    else
    {
      globus_gss_assist_display_status(
        stderr, "Failed to establish security context: ",
        majorStatus, minorStatus, 0);

    	return TCL_ERROR;
    }
  }
}

/* ----------------------------------------------------------------- */

static int
GsiftpWrapObjCmd(GsiftpContext *statePtr, Tcl_Interp *interp, Tcl_Obj *CONST obj)
{
  OM_uint32 majorStatus, minorStatus;

  gss_buffer_desc bufferIn, bufferOut;

  char *data;
  int length;

  Tcl_Obj *result;

  data = Tcl_GetStringFromObj(obj, &length);

  bufferIn.value = data;
  bufferIn.length = length;

  majorStatus = gss_wrap(&minorStatus,
                         statePtr->gssContext,
                         0, GSS_C_QOP_DEFAULT,
                         &bufferIn,
                         NULL,
                         &bufferOut);

  if(majorStatus == GSS_S_COMPLETE)
  {
    result = Tcl_NewStringObj("MIC ", -1);

    GsiftpBase64Encode(bufferOut.value, bufferOut.length, result);

    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);

    Tcl_SetObjResult(interp, result);

  	return TCL_OK;
  }
  else
  {
    globus_gss_assist_display_status(
      stderr, "Failed to wrap buffer: ",
      majorStatus, minorStatus, 0);

  	return TCL_ERROR;
  }
}

/* ----------------------------------------------------------------- */

static int
GsiftpUnwrapObjCmd(GsiftpContext *statePtr, Tcl_Interp *interp, Tcl_Obj *CONST obj)
{
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferIn, bufferOut;

  char *data;
  int length, offset;

  Tcl_Obj *result;

  data = Tcl_GetStringFromObj(obj, &length);
  result = Tcl_NewObj();

  offset = 0;

  if(memcmp(data, "631", 3) == 0 ||
     memcmp(data, "632", 3) == 0 ||
     memcmp(data, "633", 3) == 0)
  {
    offset = 4;
  }

  if(GsiftpBase64Decode(data + offset, length - offset, result) < 0)
  {
    Tcl_AppendResult(interp, "Corrupted base64 data", NULL);
    return TCL_ERROR;
  }

  data = Tcl_GetStringFromObj(result, &length);

  bufferIn.value = data;
  bufferIn.length = length;

  majorStatus = gss_unwrap(&minorStatus,
                           statePtr->gssContext,
                           &bufferIn,
                           &bufferOut,
                           NULL, GSS_C_QOP_DEFAULT);

  if(majorStatus == GSS_S_COMPLETE)
  {
    result = Tcl_NewObj();

    Tcl_AppendToObj(result, bufferOut.value, bufferOut.length);

    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);

    Tcl_SetObjResult(interp, result);

  	return TCL_OK;
  }
  else
  {
    globus_gss_assist_display_status(
      stderr, "Failed to unwrap buffer: ",
      majorStatus, minorStatus, 0);

    return TCL_ERROR;
  }
}

/* ----------------------------------------------------------------- */

static int
GsiftpContextObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
  char *option;

  GsiftpContext *statePtr = (GsiftpContext *) clientData;

  if(objc < 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "command ?arg?");
    return TCL_ERROR;
  }

  option = Tcl_GetStringFromObj(objv[1], NULL);

	if(strcmp(option, "handshake") == 0)
  {
		if(objc != 3)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "handshake data");
			return TCL_ERROR;
		}
		return GsiftpHandshakeObjCmd(statePtr, interp, objv[2]);
  }
  else if(strcmp(option, "wrap") == 0)
  {
		if(objc != 3)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "wrap data");
			return TCL_ERROR;
		}
		return GsiftpWrapObjCmd(statePtr, interp, objv[2]);
  }
  else if(strcmp(option, "unwrap") == 0)
  {
		if(objc != 3)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "unwrap data");
			return TCL_ERROR;
		}
		return GsiftpUnwrapObjCmd(statePtr, interp, objv[2]);
  }
  else if(strcmp(option, "destroy") == 0)
  {
		if(objc != 2)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "destroy");
			return TCL_ERROR;
		}
		Tcl_DeleteCommandFromToken(interp, statePtr->token);
		return TCL_OK;
  }

  Tcl_AppendResult(interp, "bad option \"", option,
    "\": must be handshake, wrap, unwrap, or destroy", NULL);
	return TCL_ERROR;
}

/* ----------------------------------------------------------------- */

static int
GsiftpCreateContextObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
	static uint64_t contextID = 0;
  char name[256];

  Tcl_Channel channel, delegate;
  ClientData delegateInstData;
  GssState *delegateStatePtr;
  Tcl_ChannelType *delegateChannelTypePtr;

  GsiftpContext *statePtr;

  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc gssNameBuf;

  Tcl_DString peerName;
  Tcl_Obj *peerNameObj;
  char *peerNameStr;
  char *channelName;
  int peerNameLen;

  int idx;

  if(0) printf("---> GsiftpCreateContextObjCmd -> 0\n");
  fflush(stdout);

  if(objc < 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "channel ?options?");
    return TCL_ERROR;
  }

  channel = Tcl_GetChannel(interp, Tcl_GetStringFromObj(objv[1], NULL), NULL);
  if(channel == (Tcl_Channel) NULL)
  {
    if(0) printf("---> GsiftpCreateContextObjCmd -> 1\n");

    return TCL_ERROR;
  }

  channelName = NULL;
  delegate = (Tcl_Channel) NULL;

  for(idx = 2; idx < objc; ++idx)
  {
    char *option = Tcl_GetString(objv[idx]);

    if(option[0] != '-') break;

    if(strcmp(option, "-delegate") == 0)
    {
      if(++idx >= objc)
      {
        Tcl_WrongNumArgs(interp, 1, objv, "channel -delegate channel");
        return TCL_ERROR;
      }

      channelName = Tcl_GetString(objv[idx]);

      continue;
    }

    Tcl_AppendResult(interp, "bad option \"", option,
      "\": should be delegate", (char *) NULL);

    return TCL_ERROR;
  }

  if(channelName != NULL)
  {
    delegate = Tcl_GetChannel(interp, channelName, NULL);
    if(delegate == (Tcl_Channel) NULL)
    {
      Tcl_AppendResult(interp, "Cannot find channel ", channelName, NULL);
      return TCL_ERROR;
    }

    delegateChannelTypePtr = Tcl_GetChannelType(delegate);

    if(delegateChannelTypePtr == NULL)
    {
      Tcl_AppendResult(interp, "Cannot define type of channel ", channelName, NULL);
      return TCL_ERROR;
    }

    if(strcmp(delegateChannelTypePtr->typeName, "gss"))
    {
      Tcl_AppendResult(interp, "Channel ", channelName, " is not of type gss.", NULL);
      return TCL_ERROR;
    }

    delegateInstData = Tcl_GetChannelInstanceData(delegate);
    delegateStatePtr = (GssState *) delegateInstData;

    if(delegateStatePtr->gssDelegProxy == GSS_C_NO_CREDENTIAL)
    {
      Tcl_AppendResult(interp, "Failed to acquire delegated credentials.", NULL);
  		return TCL_ERROR;
    }
  }

  statePtr = (GsiftpContext *) ckalloc((unsigned int) sizeof(GsiftpContext));
  memset(statePtr, 0, sizeof(GsiftpContext));

  statePtr->channel = channel;

  statePtr->delegate = delegate;

  statePtr->gssName = GSS_C_NO_NAME;
  statePtr->gssContext = GSS_C_NO_CONTEXT;
  statePtr->gssCredential = GSS_C_NO_CREDENTIAL;
  statePtr->gssDelegProxy = GSS_C_NO_CREDENTIAL;

  Tcl_DStringInit(&peerName);

  Tcl_GetChannelOption(interp, channel, "-peername", &peerName);
  peerNameObj = Tcl_NewStringObj(Tcl_DStringValue(&peerName), -1);
  Tcl_ListObjIndex(interp, peerNameObj, 1, &peerNameObj);
  peerNameStr = Tcl_GetStringFromObj(peerNameObj, &peerNameLen);

  Tcl_DStringFree(&peerName);

  /* extract the name associated with the creds */
  gssNameBuf.value = peerNameStr;
  gssNameBuf.length = peerNameLen + 1;
  majorStatus = gss_import_name(&minorStatus,
                                &gssNameBuf,
                                GSS_C_NT_HOSTBASED_SERVICE,
                                &statePtr->gssName);

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(
      stderr, "Failed to determine server name: ",
      majorStatus, minorStatus, 0);

    GsiftpDestroy((ClientData) statePtr);
    return TCL_ERROR;
  }

  if(delegate == (Tcl_Channel) NULL)
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

      GsiftpDestroy((ClientData) statePtr);
      return TCL_ERROR;
    }
  }
  else
  {
    statePtr->gssCredential = delegateStatePtr->gssDelegProxy;
  }

	sprintf(name, "gss::ftpcontext%llu", contextID++);
  statePtr->token = Tcl_CreateObjCommand(interp, name, GsiftpContextObjCmd,
    (ClientData) statePtr, GsiftpDestroy);

  Tcl_SetResult(interp, name, TCL_VOLATILE);
	return TCL_OK;
}

/* ----------------------------------------------------------------- */

int
Gtlite_Init(Tcl_Interp *interp)
{
  Tcl_CreateObjCommand(interp, "gss::import", GssImportObjCmd,
    (ClientData) 0, (Tcl_CmdDeleteProc *) NULL);

  Tcl_CreateObjCommand(interp, "gss::context", GsiftpCreateContextObjCmd,
    (ClientData) 0, (Tcl_CmdDeleteProc *) NULL);

  return Tcl_PkgProvide(interp, "gtlite", "0.1");
}

/* ----------------------------------------------------------------- */

int
Gtlite_SafeInit(Tcl_Interp *interp)
{
  return Gtlite_Init(interp);
}
