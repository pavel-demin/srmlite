#include <tcl.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>

#include <gssapi.h>
#include <globus_gss_assist.h>

#include "gss_socket.h"

/* ----------------------------------------------------------------- */

#define XX 100

static unsigned char GssBase64Pad = '=';

static unsigned char GssBase64CharSet[64] =
"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static unsigned char GssBase64CharIndex[256] = {
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

typedef struct GssContext {
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
} GssContext;

/* ----------------------------------------------------------------- */

static int GssBase64Encode(CONST unsigned char *inputBuffer,
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
        buffer[j++] = GssBase64CharSet[inputBuffer[i] >> 2];
        character = (inputBuffer[i] & 3) << 4;
        break;
      case 1:
        buffer[j++] = GssBase64CharSet[character | inputBuffer[i] >> 4];
        character = (inputBuffer[i] & 15) << 2;
        break;
      case 2:
        buffer[j++] = GssBase64CharSet[character | inputBuffer[i] >> 6];
        buffer[j++] = GssBase64CharSet[inputBuffer[i] & 63];
        character = 0; j = 0;
        Tcl_AppendToObj(outputObject, buffer, 4);
    }
  }

  if(i % 3)
  {
    buffer[j++] = GssBase64CharSet[character];
  }

  switch(i % 3)
  {
    case 1:
      buffer[j++] = GssBase64Pad;
    case 2:
      buffer[j++] = GssBase64Pad;
      Tcl_AppendToObj(outputObject, buffer, 4);
  }

  return j;
}

/* ----------------------------------------------------------------- */

static int GssBase64Decode(CONST unsigned char *inputBuffer,
                              int inputBufferSize,
                              Tcl_Obj *outputObject)
{
  int i, j;
  unsigned char index;
  unsigned char buffer[3];

  for(i = 0, j = 0; inputBuffer[i] != GssBase64Pad && i < inputBufferSize; ++i)
  {
    index = GssBase64CharIndex[inputBuffer[i]];

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
GssDestroy(ClientData clientData)
{
  OM_uint32 majorStatus, minorStatus;
  GssContext *statePtr = (GssContext *) clientData;

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
GssHandshakeObjCmd(GssContext *statePtr, Tcl_Interp *interp, Tcl_Obj *CONST obj)
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

    if(GssBase64Decode(data + offset, length - offset, result) < 0)
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

    GssBase64Encode(bufferOut.value, bufferOut.length, result);

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

      GssBase64Encode(bufferOut.value, bufferOut.length, result);

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
GssWrapObjCmd(GssContext *statePtr, Tcl_Interp *interp, Tcl_Obj *CONST obj)
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

    GssBase64Encode(bufferOut.value, bufferOut.length, result);

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
GssUnwrapObjCmd(GssContext *statePtr, Tcl_Interp *interp, Tcl_Obj *CONST obj)
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

  if(GssBase64Decode(data + offset, length - offset, result) < 0)
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
GssContextObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
  char *option;

  GssContext *statePtr = (GssContext *) clientData;

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
		return GssHandshakeObjCmd(statePtr, interp, objv[2]);
  }
  else if(strcmp(option, "wrap") == 0)
  {
		if(objc != 3)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "wrap data");
			return TCL_ERROR;
		}
		return GssWrapObjCmd(statePtr, interp, objv[2]);
  }
  else if(strcmp(option, "unwrap") == 0)
  {
		if(objc != 3)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "unwrap data");
			return TCL_ERROR;
		}
		return GssUnwrapObjCmd(statePtr, interp, objv[2]);
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
GssCreateContextObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
  char name[256];

  Tcl_Channel channel, delegate;
  ClientData delegateInstData;
  GssState *delegateStatePtr;
  Tcl_ChannelType *delegateChannelTypePtr;

  GssContext *statePtr;

  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc gssNameBuf;

  Tcl_DString peerName;
  Tcl_Obj *peerNameObj;
  char *peerNameStr;
  char *channelName;
  int peerNameLen;

  int idx;

  if(0) printf("---> GssCreateContextObjCmd -> 0\n");
  fflush(stdout);

  if(objc < 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "channel ?options?");
    return TCL_ERROR;
  }

  channel = Tcl_GetChannel(interp, Tcl_GetStringFromObj(objv[1], NULL), NULL);
  if(channel == (Tcl_Channel) NULL)
  {
    if(0) printf("---> GssCreateContextObjCmd -> 1\n");

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

  statePtr = (GssContext *) ckalloc((unsigned int) sizeof(GssContext));
  memset(statePtr, 0, sizeof(GssContext));

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

    GssDestroy((ClientData) statePtr);
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

      GssDestroy((ClientData) statePtr);
      return TCL_ERROR;
    }
  }
  else
  {
    statePtr->gssCredential = delegateStatePtr->gssDelegProxy;
  }

	sprintf(name, "gss::context%s", Tcl_GetChannelName(channel));
  statePtr->token = Tcl_CreateObjCommand(interp, name, GssContextObjCmd,
    (ClientData) statePtr, GssDestroy);

  Tcl_SetResult(interp, name, TCL_VOLATILE);
	return TCL_OK;
}

/* ----------------------------------------------------------------- */

int
Gssctx_Init(Tcl_Interp *interp)
{
  Tcl_CreateObjCommand(interp, "gss::context", GssCreateContextObjCmd,
    (ClientData) 0, (Tcl_CmdDeleteProc *) NULL);

  return Tcl_PkgProvide(interp, "gss::context", "0.1");
}

/* ----------------------------------------------------------------- */

int
Gssctx_SafeInit(Tcl_Interp *interp)
{
  return Gssctx_Init(interp);
}