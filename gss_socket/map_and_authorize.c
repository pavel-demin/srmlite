#include <stdio.h>
#include <string.h>

#include <gssapi.h>
#include <globus_gss_assist.h>


OM_uint32 init_context(gss_cred_id_t *gssClientCred, gss_ctx_id_t *gssClientContext,
  gss_name_t *gssServerName, gss_buffer_desc *bufferIn, gss_buffer_desc *bufferOut)
{

  OM_uint32 majorStatus, minorStatus;

  OM_uint32 gssFlags, gssTime;

  majorStatus
    = gss_init_sec_context(&minorStatus,        /* (out) minor status */
                           *gssClientCred,       /* (in) cred handle */
                           gssClientContext,   /* (in) sec context */
                           *gssServerName,       /* (in) name of target */
                           GSS_C_NO_OID,        /* (in) mech type */
                           GSS_C_MUTUAL_FLAG |
                           GSS_C_GLOBUS_LIMITED_DELEG_PROXY_FLAG |
                           GSS_C_DELEG_FLAG,    /* (in) request flags */
                           0,                   /* (in) time ctx is valid */
                           GSS_C_NO_CHANNEL_BINDINGS, /* (in) chan binding */
                           bufferIn,           /* (in) input token */
                           NULL,                /* (out) actual mech */
                           bufferOut,          /* (out) output token */
                           &gssFlags,           /* (out) return flags */
                           &gssTime);           /* (out) time ctx is valid */

  if(bufferIn->value != NULL)
  {
    gss_release_buffer(&minorStatus, bufferIn);
    bufferIn->value = NULL;
  }

  if(!(majorStatus & GSS_S_CONTINUE_NEEDED) && (majorStatus != GSS_S_COMPLETE))
  {
    globus_gss_assist_display_status(
      stderr, "Failed to establish security context: ",
      majorStatus, minorStatus, 0);
  }

  return majorStatus;
}


OM_uint32 accept_context(gss_cred_id_t *gssServerCred, gss_ctx_id_t *gssServerContext,
  gss_name_t *gssClientName, gss_buffer_desc *bufferIn, gss_buffer_desc *bufferOut)
{

  OM_uint32 majorStatus, minorStatus;

  OM_uint32 gssFlags, gssTime;

  gss_cred_id_t gssCredProxy;

  majorStatus
    = gss_accept_sec_context(&minorStatus,        /* (out) minor status */
                             gssServerContext,   /* (in) security context */
                             *gssServerCred,       /* (in) cred handle */
                             bufferOut,          /* (in) input token */
                             GSS_C_NO_CHANNEL_BINDINGS, /* (in) chan binding*/
                             gssClientName,      /* (out) name of initiator */
                             NULL,                /* (out) mechanisms */
                             bufferIn,           /* (out) output token */
                             &gssFlags,           /* (out) return flags */
                             &gssTime,            /* (out) time ctx is valid */
                             &gssCredProxy);      /* (out) delegated cred */

  if(bufferOut->value != NULL)
  {
    gss_release_buffer(&minorStatus, bufferOut);
    bufferOut->value = NULL;
  }

  if(!(majorStatus & GSS_S_CONTINUE_NEEDED) && (majorStatus != GSS_S_COMPLETE))
  {
    globus_gss_assist_display_status(
      stderr, "Failed to establish security context: ",
      majorStatus, minorStatus, 0);
  }

  return majorStatus;
}


int main(int argc, char *argv[])
{
  if(argc < 2) return 1;

  OM_uint32 majorStatus, minorStatus;

  gss_cred_id_t gssClientCred, gssServerCred;
  gss_ctx_id_t gssClientContext, gssServerContext;

  gss_name_t gssClientName, gssServerName;

  gss_buffer_desc gssNameBuf;

  gss_buffer_desc bufferIn, bufferOut, gssCredBuf;

  globus_result_t result;
  
  int contextEstablished;

  char gssUser[256];

  memset(gssUser, 0, 256);

  majorStatus = gss_acquire_cred(&minorStatus,     /* (out) minor status */
                                 GSS_C_NO_NAME,    /* (in) desired name */
                                 GSS_C_INDEFINITE, /* (in) desired time valid */
                                 GSS_C_NO_OID_SET, /* (in) desired mechs */
                                 GSS_C_BOTH,       /* (in) cred usage */
                                 &gssServerCred,   /* (out) cred handle */
                                 NULL,             /* (out) actual mechs */
                                 NULL);            /* (out) actual time valid */

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(
      stderr, "Failed to acquire credentials: ",
      majorStatus, minorStatus, 0);

    return 1;
  }

  majorStatus = gss_inquire_cred(&minorStatus,
                                 gssServerCred,
                                 &gssServerName,
                                 NULL, NULL, NULL);

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(
      stderr, "Failed to determine server name: ",
      majorStatus, minorStatus, 0);

    return 1;
  }

  majorStatus = gss_display_name(&minorStatus,
                                 gssServerName,
                                 &gssNameBuf,
                                 NULL);


  gssCredBuf.length = strlen(argv[1]) + 17;
  gssCredBuf.value = malloc(gssCredBuf.length);
  memset(gssCredBuf.value, 0, gssCredBuf.length);
  strcat(gssCredBuf.value, "X509_USER_PROXY=");
  strcat(gssCredBuf.value, argv[1]);

  majorStatus = gss_import_cred(&minorStatus,     /* (out) minor status */
                                &gssClientCred,   /* (out) cred handle */
                                GSS_C_NO_OID,     /* (in) desired mechs */
                                1,                /* (in) option_req used by gss_export_cred */
                                &gssCredBuf,      /* (in) buffer produced by gss_export_cred */
                                GSS_C_INDEFINITE, /* (in) desired time valid */
                                NULL);            /* (out) actual time valid */

  unlink(argv[1]);

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(
      stderr, "Failed to acquire credentials: ",
      majorStatus, minorStatus, 0);

    return 1;
  }

  majorStatus = gss_inquire_cred(&minorStatus,
                                 gssClientCred,
                                 &gssClientName,
                                 NULL, NULL, NULL);

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(
      stderr, "Failed to determine client name: ",
      majorStatus, minorStatus, 0);

    return 1;
  }

  majorStatus = gss_display_name(&minorStatus,
                                 gssClientName,
                                 &gssNameBuf,
                                 NULL);


  contextEstablished = 0;
  gssClientContext = GSS_C_NO_CONTEXT;
  gssServerContext = GSS_C_NO_CONTEXT;
  bufferIn.value = NULL;
  bufferIn.length = 0;


  while(!contextEstablished)
  {

    majorStatus = init_context(&gssClientCred, &gssClientContext,
      &gssServerName, &bufferIn, &bufferOut);

    if(!(majorStatus & GSS_S_CONTINUE_NEEDED) && (majorStatus != GSS_S_COMPLETE))
    {
      return 1;
    }

    majorStatus = accept_context(&gssServerCred, &gssServerContext,
      &gssClientName, &bufferIn, &bufferOut);

    if(!(majorStatus & GSS_S_CONTINUE_NEEDED))
    {
      if(majorStatus == GSS_S_COMPLETE)
      {

        majorStatus = gss_display_name(&minorStatus,
                                       gssClientName,
                                       &gssNameBuf,
                                       NULL);

        fclose(stderr);
        stderr = fopen("/dev/null", "r+");
        result = globus_gss_assist_map_and_authorize(gssServerContext,
                                                     "srm", NULL,
                                                     gssUser, 256);
        fclose(stderr);
        printf("%s\n", gssUser);
        contextEstablished = 1;
      }
      else
      {
        globus_gss_assist_display_status(
          stderr, "Failed to establish security context: ",
          majorStatus, minorStatus, 0);
        return 1;
      }
    }
  }
  return 0;
}


