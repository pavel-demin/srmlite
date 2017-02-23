#include <stdio.h>
#include <string.h>

#include <globus/gssapi.h>
#include <globus/globus_gss_assist.h>

#define XX 100

const char Base64Pad = '=';

const char Base64CharIndex[256] = {
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

int main(int argc, char *argv[])
{
  OM_uint32 majorStatus, minorStatus;
  gss_buffer_desc gssContextBuffer;
  gss_ctx_id_t gssContext;
  globus_result_t result;

  int i, j;
  char index;
  char buffer[32768];
  unsigned char *input;
  char output[256];

  memset(output, 0, 256);

  if(argc < 2) return 1;

  input = argv[1];

  index = XX;
  j = 0;

  for(i = 0; input[i] != Base64Pad && input[i] != 0 && i < 32768; ++i)
  {
    index = Base64CharIndex[input[i]];

    if(index == XX) return 1;

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
        buffer[j++] |= index;
    }
  }

  switch(i & 3)
  {
    case 1:
      return 1;
    case 2:
      if(index & 15)
      {
        return 1;
      }
      if(memcmp(input + i, "==", 2))
      {
        return 1;
      }
      break;
    case 3:
      if(index & 3)
      {
        return 1;
      }
      if(memcmp(input + i, "=", 1))
      {
        return 1;
      }
  }

  gssContextBuffer.length = j;
  gssContextBuffer.value = buffer;

  majorStatus = gss_import_sec_context(&minorStatus, &gssContextBuffer, &gssContext);

  if(majorStatus != GSS_S_COMPLETE)
  {
    globus_gss_assist_display_status(stderr, "Failed to import context: ", majorStatus, minorStatus, 0);
    return 1;
  }

  fclose(stderr);
  stderr = fopen("/dev/null", "r+");
  result = globus_gss_assist_map_and_authorize(gssContext, "srm", NULL, output, 256);
  fclose(stderr);

  if(result != GLOBUS_SUCCESS)
  {
    printf("%s\n", globus_error_print_chain(globus_error_get(result)));
    return 1;
  }

  printf("%s\n", output);

  return 0;
}
