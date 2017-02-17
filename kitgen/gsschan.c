
/*
  Copyright (c) 2017, Pavel Demin

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

/* ----------------------------------------------------------------- */

#define GSS_TCL_HANDSHAKE (1<<0)
#define GSS_TCL_READABLE  (1<<1)

/* ----------------------------------------------------------------- */

static int  GssClose(ClientData instanceData, Tcl_Interp *interp);
static int  GssInput(ClientData instanceData, char *buffer, int length, int *errorCodePtr);
static int  GssOutput(ClientData instanceData, const char *buffer, int length, int *errorCodePtr);
static int  GssGetOption(ClientData instanceData, Tcl_Interp *interp, const char *optionName, Tcl_DString *optionValue);
static void GssWatch(ClientData instanceData, int mask);
static void GssHandler(ClientData instanceData, int mask);

/* ----------------------------------------------------------------- */

typedef struct {
  Tcl_Channel parent;
  Tcl_Channel channel;
  unsigned char buffer[16389];
  int length, flags;
  gss_cred_id_t gssCredential;
  gss_cred_id_t gssCredProxy;
  gss_ctx_id_t gssContext;
  gss_name_t gssName;
  gss_buffer_desc gssNameBuf;
  OM_uint32 gssFlags;
  OM_uint32 gssTime;

  Tcl_Interp *interp;
} GssState;

/* ----------------------------------------------------------------- */

static Tcl_ChannelType ChannelType = {
  "gss",
  TCL_CHANNEL_VERSION_2,
  GssClose,
  GssInput,
  GssOutput,
  NULL,   /* SeekProc */
  NULL,   /* SetOptionProc */
  GssGetOption,
  GssWatch,
  NULL,   /* GetHandleProc */
  NULL,   /* Close2Proc */
  NULL,   /* BlockModeProc */
  NULL,   /* FlushProc */
  NULL    /* HandlerProc */
};

/* ----------------------------------------------------------------- */

static unsigned char GssBase64Pad = '=';

static unsigned char GssBase64CharSet[64] =
"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* ----------------------------------------------------------------- */

static void
GssBase64Encode(Tcl_DString *outputString, unsigned char *inputBuffer, int length)
{
  int i, j;
  unsigned char character;
  unsigned char buffer[4];

  character = 0;

  for(i = 0, j = 0; i < length; ++i)
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
        Tcl_DStringAppend(outputString, buffer, 4);
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
      Tcl_DStringAppend(outputString, buffer, 4);
  }
}

/* ----------------------------------------------------------------- */

static void
GssClean(GssState *state)
{
  OM_uint32 majorStatus, minorStatus;

  if(state->gssCredential != GSS_C_NO_CREDENTIAL)
  {
    majorStatus
      = gss_release_cred(&minorStatus,
                         &state->gssCredential);
  }

  if(state->gssCredProxy != GSS_C_NO_CREDENTIAL)
  {
    majorStatus
      = gss_release_cred(&minorStatus,
                         &state->gssCredProxy);
  }

  if(state->gssContext != GSS_C_NO_CONTEXT)
  {
    majorStatus
      = gss_delete_sec_context(&minorStatus,
                               &state->gssContext,
                               GSS_C_NO_BUFFER);
  }

  if(state->gssName != GSS_C_NO_NAME)
  {
    majorStatus
      = gss_release_name(&minorStatus,
                         &state->gssName);
  }

  if(state->gssNameBuf.value != NULL)
  {
    majorStatus
      = gss_release_buffer(&minorStatus,
                           &state->gssNameBuf);
  }

  ckfree((char *) state);
}

/* ----------------------------------------------------------------- */

static int
GssClose(ClientData instanceData,  Tcl_Interp *interp)
{
  GssState *state = (GssState *) instanceData;
  GssClean(state);
  return TCL_OK;
}

/* ----------------------------------------------------------------- */

static int
GssInput(ClientData instanceData, char *buffer, int length, int *errorCodePtr)
{
  GssState *state = (GssState *) instanceData;
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferIn, bufferOut;
  int result;

  state->flags &= ~(GSS_TCL_READABLE);

  if(state->length > 0)
  {
    bufferIn.value = state->buffer;
    bufferIn.length = state->length;
    state->length = 0;

    majorStatus
      = gss_unwrap(&minorStatus,
                   state->gssContext,
                   &bufferIn,
                   &bufferOut,
                   NULL, GSS_C_QOP_DEFAULT);

    if(majorStatus == GSS_S_COMPLETE)
    {
      memcpy(buffer, bufferOut.value, bufferOut.length);
      result = bufferOut.length;
      majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
      return result;
    }
    else
    {
      *errorCodePtr = EIO;
      return -1;
    }
  }
  else
  {
    *errorCodePtr = EIO;
    return -1;
  }
}

/* ----------------------------------------------------------------- */

static int
GssOutput(ClientData instanceData, const char *buffer, int length, int *errorCodePtr)
{
  GssState *state = (GssState *) instanceData;
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferIn, bufferOut;

  bufferIn.value = buffer;
  bufferIn.length = length;

  majorStatus
    = gss_wrap(&minorStatus,
               state->gssContext,
               0, GSS_C_QOP_DEFAULT,
               &bufferIn,
               NULL,
               &bufferOut);

  if(majorStatus == GSS_S_COMPLETE)
  {
    Tcl_Write(state->parent, bufferOut.value, bufferOut.length);
    Tcl_Flush(state->parent);
    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
    *errorCodePtr = 0;
    return length;
  }
  else
  {
    *errorCodePtr = EIO;
    return -1;
  }
}

/* ----------------------------------------------------------------- */

static int
GssGetOption(ClientData instanceData, Tcl_Interp *interp, const char *optionName, Tcl_DString *optionValue)
{
  GssState *state = (GssState *) instanceData;
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferOut;

  if(optionName == NULL)
  {
    return TCL_OK;
  }
  else if(strcmp(optionName, "-gssname") == 0)
  {
    Tcl_DStringAppend(optionValue, state->gssNameBuf.value, state->gssNameBuf.length);
    return TCL_OK;
  }
  else if(strcmp(optionName, "-gsscontext") == 0)
  {
    majorStatus
      = gss_export_sec_context(&minorStatus,
                               &state->gssContext,
                               &bufferOut);

    if(majorStatus == GSS_S_COMPLETE)
    {
      GssBase64Encode(optionValue, bufferOut.value, bufferOut.length);
      return TCL_OK;
    }
    else
    {
      Tcl_AppendResult(interp, "Failed to export context", NULL);
      return TCL_ERROR;
    }
  }

  return Tcl_BadChannelOption(interp, optionName, "gssname gsscontext");
}

/* ----------------------------------------------------------------- */

static void
GssWatch(ClientData instanceData, int mask)
{
  GssState *state = (GssState *) instanceData;

  if(mask & TCL_READABLE)
  {
    if(state->flags & GSS_TCL_READABLE)
    {
      Tcl_NotifyChannel(state->channel, TCL_READABLE);
    }
    else
    {
      Tcl_CreateChannelHandler(state->parent, TCL_READABLE, GssHandler, instanceData);
    }
  }
  else
  {
    Tcl_DeleteChannelHandler(state->parent, GssHandler, instanceData);
  }
}

/* ----------------------------------------------------------------- */

static int
GssHandshake(GssState *state)
{
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferIn, bufferOut;

  bufferIn.value = state->buffer;
  bufferIn.length = state->length;
  state->length = 0;

  majorStatus
    = gss_accept_sec_context(&minorStatus,              /* (out) minor status */
                             &state->gssContext,        /* (in) security context */
                             state->gssCredential,      /* (in) cred handle */
                             &bufferIn,                 /* (in) input token */
                             GSS_C_NO_CHANNEL_BINDINGS, /* (in) */
                             &state->gssName,           /* (out) name of initiator */
                             NULL,                      /* (out) mechanisms */
                             &bufferOut,                /* (out) output token */
                             &state->gssFlags,          /* (out) return flags */
                             &state->gssTime,           /* (out) time ctx is valid */
                             &state->gssCredProxy);     /* (out) delegated cred */

  if(majorStatus & GSS_S_CONTINUE_NEEDED)
  {
    Tcl_Write(state->parent, bufferOut.value, bufferOut.length);
    Tcl_Flush(state->parent);
    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
  }
  else
  {
    if(majorStatus == GSS_S_COMPLETE)
    {
      majorStatus
        = gss_display_name(&minorStatus,
                           state->gssName,
                           &state->gssNameBuf,
                           NULL);
      Tcl_Write(state->parent, bufferOut.value, bufferOut.length);
      Tcl_Flush(state->parent);
      majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
      state->flags &= ~(GSS_TCL_HANDSHAKE);
    }
    else
    {
      Tcl_NotifyChannel(state->channel, TCL_READABLE);
    }
  }
}

/* ----------------------------------------------------------------- */

static void
GssHandler(ClientData instanceData, int mask)
{
  GssState *state = (GssState *) instanceData;
  int length;

  if(state->length < 5)
  {
    state->length += Tcl_Read(state->parent, state->buffer + state->length, 5 - state->length);
    if(state->length < 5)
    {
      if(Tcl_Eof(state->parent))
      {
        Tcl_NotifyChannel(state->channel, TCL_READABLE);
      }
      return;
    }
  }
  length = (((int) state->buffer[3]) << 8 | ((int) state->buffer[4])) + 5;
  if(length < 5 || length > 16389)
  {
    Tcl_NotifyChannel(state->channel, TCL_READABLE);
    return;
  }
  if(state->length < length)
  {
    state->length += Tcl_Read(state->parent, state->buffer + state->length, length - state->length);
    if(state->length < length)
    {
      if(Tcl_Eof(state->parent))
      {
        Tcl_NotifyChannel(state->channel, TCL_READABLE);
      }
      return;
    }
  }
  if(state->flags & GSS_TCL_HANDSHAKE)
  {
    GssHandshake(state);
  }
  else
  {
    state->flags |= GSS_TCL_READABLE;
    Tcl_NotifyChannel(state->channel, TCL_READABLE);
  }
}

/* ----------------------------------------------------------------- */

static int
GssChannelObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
  Tcl_Channel channel;
  GssState *state;
  OM_uint32 majorStatus, minorStatus;
  static unsigned long gssCounter = 0;
  char gssString[32];

  if(objc < 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "channel");
    return TCL_ERROR;
  }

  channel = Tcl_GetChannel(interp, Tcl_GetStringFromObj(objv[1], NULL), NULL);
  if(channel == NULL)
  {
    Tcl_AppendResult(interp, "Failed to get channel", NULL);
    return TCL_ERROR;
  }
  channel = Tcl_GetTopChannel(channel);

  state = (GssState *) ckalloc(sizeof(GssState));
  memset(state, 0, sizeof(GssState));

  state->gssCredential = GSS_C_NO_CREDENTIAL;
  state->gssCredProxy = GSS_C_NO_CREDENTIAL;
  state->gssContext = GSS_C_NO_CONTEXT;
  state->gssName = GSS_C_NO_NAME;

  state->gssNameBuf.value = NULL;
  state->gssNameBuf.length = 0;

  majorStatus
    = gss_acquire_cred(&minorStatus,          /* (out) minor status */
                       GSS_C_NO_NAME,         /* (in) desired name */
                       GSS_C_INDEFINITE,      /* (in) desired time valid */
                       GSS_C_NO_OID_SET,      /* (in) desired mechs */
                       GSS_C_BOTH,            /* (in) cred usage */
                       &state->gssCredential, /* (out) cred handle */
                       NULL,                  /* (out) actual mechs */
                       NULL);                 /* (out) actual time valid */

  if(majorStatus != GSS_S_COMPLETE)
  {
    GssClean(state);
    Tcl_AppendResult(interp, "Failed to acquire credentials", NULL);
    return TCL_ERROR;
  }

  state->interp = interp;

  sprintf(gssString, "gsschan%d", gssCounter);
  ++gssCounter;

  state->channel = Tcl_CreateChannel(&ChannelType, gssString,
    (ClientData) state, (TCL_READABLE | TCL_WRITABLE | TCL_EXCEPTION));

  if(state->channel == NULL)
  {
    GssClean(state);
    Tcl_AppendResult(interp, "Failed to create channel", NULL);
    return TCL_ERROR;
  }

  Tcl_RegisterChannel(interp, state->channel);

  state->parent = channel;

  Tcl_SetChannelBufferSize(state->parent, 16389);
  Tcl_SetChannelBufferSize(state->channel, 16360);

  state->flags = GSS_TCL_HANDSHAKE;

  Tcl_AppendResult(interp, gssString, NULL);
  return TCL_OK;
}

/* ----------------------------------------------------------------- */

int
Gsschan_Init(Tcl_Interp *interp)
{
  Tcl_CreateObjCommand(interp, "gsschan", GssChannelObjCmd, (ClientData) 0, NULL);
  return Tcl_PkgProvide(interp, "gsschan", "0.1");
}

/* ----------------------------------------------------------------- */

int
Gsschan_SafeInit(Tcl_Interp *interp)
{
  return Gsschan_Init(interp);
}
