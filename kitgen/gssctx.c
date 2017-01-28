
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

#include <gssapi.h>
#include <globus_gss_assist.h>

/* ----------------------------------------------------------------- */

typedef struct GssContext {
  Tcl_Command token;
  Tcl_Channel channel;
  unsigned char buffer[16389];
  int length, state;
  gss_cred_id_t gssCredential;
  gss_cred_id_t gssCredProxy;
  gss_ctx_id_t gssContext;
  gss_name_t gssName;
  gss_buffer_desc gssNameBuf;
  OM_uint32 gssFlags;
  OM_uint32 gssTime;
} GssContext;

/* ----------------------------------------------------------------- */

static int
GssHandshake(Tcl_Interp *interp, GssContext *context)
{
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferIn, bufferOut;

  bufferIn.value = context->buffer;
  bufferIn.length = context->length;
  context->length = 0;

  majorStatus
    = gss_accept_sec_context(&minorStatus,              /* (out) minor status */
                             &context->gssContext,      /* (in) security context */
                             context->gssCredential,    /* (in) cred handle */
                             &bufferIn,                 /* (in) input token */
                             GSS_C_NO_CHANNEL_BINDINGS, /* (in) */
                             &context->gssName,         /* (out) name of initiator */
                             NULL,                      /* (out) mechanisms */
                             &bufferOut,                /* (out) output token */
                             &context->gssFlags,        /* (out) return flags */
                             &context->gssTime,         /* (out) time ctx is valid */
                             &context->gssCredProxy);   /* (out) delegated cred */

  if(majorStatus & GSS_S_CONTINUE_NEEDED)
  {
    Tcl_Write(context->channel, bufferOut.value, bufferOut.length);
    Tcl_Flush(context->channel);
    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
    return 5;
  }
  else
  {
    if(majorStatus == GSS_S_COMPLETE)
    {
      majorStatus
        = gss_display_name(&minorStatus,
                           context->gssName,
                           &context->gssNameBuf,
                           NULL);
      Tcl_Write(context->channel, bufferOut.value, bufferOut.length);
      Tcl_Flush(context->channel);
      majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
      context->state = 1;
      return 5;
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
GssUnwrap(Tcl_Interp *interp, GssContext *context)
{
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferIn, bufferOut;
  Tcl_Obj *result;

  bufferIn.value = context->buffer;
  bufferIn.length = context->length;
  context->length = 0;

  majorStatus
    = gss_unwrap(&minorStatus,
                 context->gssContext,
                 &bufferIn,
                 &bufferOut,
                 NULL, GSS_C_QOP_DEFAULT);

  if(majorStatus == GSS_S_COMPLETE)
  {
    result = Tcl_NewByteArrayObj(bufferOut.value, bufferOut.length);
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
GssWrap(Tcl_Interp *interp, GssContext *context, Tcl_Obj *obj)
{
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferIn, bufferOut;
  Tcl_Obj *result;
  int length;

  bufferIn.value = Tcl_GetByteArrayFromObj(obj, &length);
  bufferIn.length = length;

  majorStatus
    = gss_wrap(&minorStatus,
               context->gssContext,
               0, GSS_C_QOP_DEFAULT,
               &bufferIn,
               NULL,
               &bufferOut);

  if(majorStatus == GSS_S_COMPLETE)
  {
    Tcl_Write(context->channel, bufferOut.value, bufferOut.length);
    Tcl_Flush(context->channel);
    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
    result = Tcl_NewIntObj(length);
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
GssExport(Tcl_Interp *interp, GssContext *context)
{
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc bufferOut;
  Tcl_Obj *result;

  majorStatus
    = gss_export_sec_context(&minorStatus,
                             &context->gssContext,
                             &bufferOut);

  if(majorStatus == GSS_S_COMPLETE)
  {
    result = Tcl_NewByteArrayObj(bufferOut.value, bufferOut.length);
    majorStatus = gss_release_buffer(&minorStatus, &bufferOut);
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
  }
  else
  {
    globus_gss_assist_display_status(
      stderr, "Failed to export context: ",
      majorStatus, minorStatus, 0);
    return TCL_ERROR;
  }
}

/* ----------------------------------------------------------------- */

static int
GssContextObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
  int length;
  char *option;
  GssContext *context = (GssContext *) clientData;
  Tcl_Obj *result;

  if(objc < 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "command ?arg?");
    return TCL_ERROR;
  }

  option = Tcl_GetStringFromObj(objv[1], NULL);

  if(strcmp(option, "read") == 0)
  {
    if(objc != 2)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "read");
      return TCL_ERROR;
    }
    if(context->length < 5)
    {
      context->length += Tcl_Read(context->channel, context->buffer + context->length, 5 - context->length);
      if(context->length < 5)
      {
        if(Tcl_Eof(context->channel))
        {
          Tcl_AppendResult(interp, "Failed to read packet length", NULL);
          return TCL_ERROR;
        }
        else
        {
          return 5;
        }
      }
    }
    length = (((int) context->buffer[3]) << 8 | ((int) context->buffer[4])) + 5;
    if(length < 5 || length > 16389)
    {
      Tcl_AppendResult(interp, "Invalid packet length", NULL);
      return TCL_ERROR;
    }
    if(context->length < length)
    {
      context->length += Tcl_Read(context->channel, context->buffer + context->length, length - context->length);
      if(context->length < length)
      {
        if(Tcl_Eof(context->channel))
        {
          Tcl_AppendResult(interp, "Failed to read packet length", NULL);
          return TCL_ERROR;
        }
        else
        {
          return 5;
        }
      }
    }
    if(context->state == 0)
    {
      return GssHandshake(interp, context);
    }
    else
    {
      return GssUnwrap(interp, context);
    }
  }
  else if(strcmp(option, "write") == 0)
  {
    if(objc != 3)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "write data");
      return TCL_ERROR;
    }
    return GssWrap(interp, context, objv[2]);
  }
  else if(strcmp(option, "name") == 0)
  {
    if(objc != 2)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "name");
      return TCL_ERROR;
    }
    result = Tcl_NewByteArrayObj(context->gssNameBuf.value, context->gssNameBuf.length);
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
  }
  else if(strcmp(option, "export") == 0)
  {
    if(objc != 2)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "export");
      return TCL_ERROR;
    }
    return GssExport(interp, context);
  }
  else if(strcmp(option, "destroy") == 0)
  {
    if(objc != 2)
    {
      Tcl_WrongNumArgs(interp, 1, objv, "destroy");
      return TCL_ERROR;
    }
    Tcl_DeleteCommandFromToken(interp, context->token);
    return TCL_OK;
  }

  Tcl_AppendResult(interp, "bad option \"", option,
    "\": must be read, write, name, context, or destroy", NULL);
  return TCL_ERROR;
}

/* ----------------------------------------------------------------- */

static void
GssContextDestroy(ClientData clientData)
{
  OM_uint32 majorStatus, minorStatus;
  GssContext *context = (GssContext *) clientData;

  if(context->gssContext != GSS_C_NO_CONTEXT)
  {
    majorStatus
      = gss_delete_sec_context(&minorStatus,
                               &context->gssContext,
                               GSS_C_NO_BUFFER);
  }

  if(context->gssCredential != GSS_C_NO_CREDENTIAL)
  {
    majorStatus
      = gss_release_cred(&minorStatus,
                         &context->gssCredential);
  }

  if(context->gssCredProxy != GSS_C_NO_CREDENTIAL)
  {
    majorStatus
      = gss_release_cred(&minorStatus,
                         &context->gssCredProxy);
  }

  if(context->gssName != GSS_C_NO_NAME)
  {
    majorStatus
      = gss_release_name(&minorStatus,
                         &context->gssName);
  }

  if(context->gssNameBuf.value != NULL)
  {
    majorStatus
      = gss_release_buffer(&minorStatus,
                           &context->gssNameBuf);
    context->gssNameBuf.value = NULL;
    context->gssNameBuf.length = 0;
  }

  ckfree(context);
}

/* ----------------------------------------------------------------- */

static int
GssCreateContextObjCmd(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj *CONST objv[])
{
  char cmdName[256];
  Tcl_CmdInfo cmdInfo;
  int cmdCounter;

  Tcl_Channel channel;
  GssContext *context;

  OM_uint32 majorStatus, minorStatus;

  if(objc != 2)
  {
    Tcl_WrongNumArgs(interp, 1, objv, "channel");
    return TCL_ERROR;
  }

  channel = Tcl_GetChannel(interp, Tcl_GetStringFromObj(objv[1], NULL), NULL);
  if(channel == (Tcl_Channel) NULL)
  {
    Tcl_AppendResult(interp, "Failed to get channel", NULL);
    return TCL_ERROR;
  }

  context = ckalloc(sizeof(GssContext));
  memset(context, 0, sizeof(GssContext));

  context->channel = channel;
  context->length = 0;
  context->state = 0;

  context->gssName = GSS_C_NO_NAME;
  context->gssContext = GSS_C_NO_CONTEXT;
  context->gssCredProxy = GSS_C_NO_CREDENTIAL;
  context->gssCredential = GSS_C_NO_CREDENTIAL;

  context->gssNameBuf.value = NULL;
  context->gssNameBuf.length = 0;

  majorStatus
    = gss_acquire_cred(&minorStatus,            /* (out) minor status */
                       GSS_C_NO_NAME,           /* (in) desired name */
                       GSS_C_INDEFINITE,        /* (in) desired time valid */
                       GSS_C_NO_OID_SET,        /* (in) desired mechs */
                       GSS_C_BOTH,              /* (in) cred usage */
                       &context->gssCredential, /* (out) cred handle */
                       NULL,                    /* (out) actual mechs */
                       NULL);                   /* (out) actual time valid */

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(
      stderr, "Failed to acquire credentials: ",
      majorStatus, minorStatus, 0);

    GssContextDestroy((ClientData) context);
    Tcl_AppendResult(interp, "Failed to acquire credentials", NULL);
    return TCL_ERROR;
  }

  cmdCounter = 0;
  do
  {
    sprintf(cmdName, "::gssctx%d", cmdCounter);
    cmdCounter++;
  }
  while(Tcl_GetCommandInfo(interp, cmdName, &cmdInfo));

  context->token = Tcl_CreateObjCommand(interp, cmdName, GssContextObjCmd,
    (ClientData) context, GssContextDestroy);

  Tcl_SetResult(interp, cmdName, TCL_VOLATILE);
  return TCL_OK;
}

/* ----------------------------------------------------------------- */

int
Gssctx_Init(Tcl_Interp *interp)
{
  Tcl_CreateObjCommand(interp, "gssctx", GssCreateContextObjCmd,
    (ClientData) 0, (Tcl_CmdDeleteProc *) NULL);

  return Tcl_PkgProvide(interp, "gssctx", "0.2");
}

/* ----------------------------------------------------------------- */

int
Gssctx_SafeInit(Tcl_Interp *interp)
{
  return Gssctx_Init(interp);
}

