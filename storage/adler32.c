/*
  gcc -O2 -Wall -lz -lhiredis adler32.c -o adler32
  strip adler32
*/

#include <stdio.h>
#include <stdlib.h>
#include <zlib.h>
#include <hiredis/hiredis.h>

#define MAX_PATH 512
#define MAX_BUFFER 1024*1024

int main(int argc, char *argv[])
{
  FILE *fp;
  char path[MAX_PATH];
  Bytef buffer[MAX_BUFFER];
  size_t size;
  redisContext *context;
  redisReply *reply;
  int type;
  uLong adler;

  if(argc != 2) return EXIT_FAILURE;

  context = redisConnect("127.0.0.1", 6379);

  if(context && !context->err)
  {
    reply = redisCommand(context, "GET %s", argv[1]);
    type = reply->type;
    if(type == REDIS_REPLY_STRING) printf("%s\n", reply->str);
    freeReplyObject(reply);
    if(type == REDIS_REPLY_STRING)
    {
      redisFree(context);
      return EXIT_SUCCESS;
    }
  }

  snprintf(path, MAX_PATH, "/srmlite/meta/cms/%s", argv[1]);

  fp = fopen(path, "rb");

  if(!fp) return EXIT_FAILURE;

  adler = adler32(0L, Z_NULL, 0);

  while((size = fread(buffer, 1, MAX_BUFFER, fp)) > 0)
  {
    adler = adler32(adler, buffer, size);
  }

  fclose(fp);

  if(context && !context->err)
  {
    reply = redisCommand(context, "SET %s %08lx", argv[1], adler);
    freeReplyObject(reply);
    redisFree(context);
  }

  printf("%08lx\n", adler);

  return EXIT_SUCCESS;
}
