#include <stdio.h>
#include <string.h>

#include <gssapi.h>
#include <globus_gss_assist.h>

int main(int argc, char *argv[])
{
  OM_uint32 majorStatus, minorStatus;

  gss_buffer_desc gssContextBuffer;
  
  gss_ctx_id_t gssContext;

  globus_result_t result;

  FILE *contextFile;

  char gssUser[256];

  memset(gssUser, 0, 256);

  if(argc < 2) return 1;

  contextFile = fopen(argv[1],"r");

  if(contextFile == NULL)
  {
    return 1;
  }

  fseek(contextFile, 0, SEEK_END);
  gssContextBuffer.length = ftell(contextFile);
  fseek(contextFile, 0, SEEK_SET);
  gssContextBuffer.value = malloc(gssContextBuffer.length);

  fread(gssContextBuffer.value, gssContextBuffer.length, 1, contextFile);

  fclose(contextFile);

  unlink(argv[1]);

  majorStatus = gss_import_sec_context(&minorStatus,
                                       &gssContextBuffer,
                                       &gssContext);

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(
      stderr, "Failed to import context: ",
      majorStatus, minorStatus, 0);

    return 1;
  }

  fclose(stderr);
  stderr = fopen("/dev/null", "r+");
  result = globus_gss_assist_map_and_authorize(gssContext,
                                               "srm", NULL,
                                               gssUser, 256);
  fclose(stderr);

  if(result != GLOBUS_SUCCESS)
  {
    printf("%s\n", globus_error_print_chain(globus_error_get(result)));
    return 1;
  }

  printf("%s\n", gssUser);

  return 0;
}


