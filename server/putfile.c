#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <sys/statvfs.h>
#include <sys/stat.h>
#include <malloc.h>
#include <libgen.h>
#include <time.h>

#define MIN_FREE_BLOCKS 512000

#define MAX_STORAGE 100

#define MAX_PATH 512

struct mounts_list
{
  char *mounts[MAX_STORAGE];
  int nmounts;
};

static struct mounts_list storage;

static int get_config(const char *cfile)
{
  FILE *fp;
  char temp[132];
  char text[132];

  if (!(fp = fopen(cfile, "r"))) {
    printf("Couldn't open config file: \"%s\"\n", cfile);
    exit(-1);
  }

  storage.nmounts = 1;

  while(fgets(text, 131, fp))
  {
    if(strncmp("storage.metapath", text, 16) == 0)
    {
      sscanf(text, "storage.metapath %s", temp);
      storage.mounts[0] = strdup(temp);
    }
    else if(strncmp("storage.datapath", text, 16) == 0)
    {
      if (storage.nmounts == MAX_STORAGE)
      {
        printf("Too many storage mount points, %d max\n", MAX_STORAGE);
        exit(-1);
      }

      sscanf(text, "storage.datapath %s", temp);

      storage.mounts[storage.nmounts] = strdup(temp);

      ++storage.nmounts;
    }
  }

  fclose(fp);

  if (!storage.mounts[0])
  {
    printf("No meta mount point defined\n");
    exit(-1);
  }

  if (storage.nmounts < 2)
  {
    printf("No data mount point defined\n");
    exit(-1);
  }

  fflush(NULL);

  return 0;
}

static int make_realdir(const char *path,
            const char *real_prfx, const char *meta_prfx,
            char *real_path, char *meta_path)
{
  int res;
  struct stat st;
  char *copy_ptr;
  char *real_ptr;
  char *meta_ptr;
  char *curr_dir;
  char *next_dir;
  char copy_path[MAX_PATH];

  real_path[0] = '\0';
  meta_path[0] = '\0';

  res = 0;

  real_ptr = real_path + sprintf(real_path, "%s", real_prfx);
  meta_ptr = meta_path + sprintf(meta_path, "%s", meta_prfx);

  strncpy(copy_path, path, MAX_PATH);
  curr_dir = strtok_r(copy_path, "/", &copy_ptr);
  while((next_dir = strtok_r(NULL, "/", &copy_ptr)))
  {
    if((real_ptr - real_path + next_dir - curr_dir + 2 > MAX_PATH) ||
       (meta_ptr - meta_path + next_dir - curr_dir + 2 > MAX_PATH))
    {
      errno = ENAMETOOLONG;
      res = -1;
      break;
    }

    real_ptr += sprintf(real_ptr, "/%s", curr_dir);
    meta_ptr += sprintf(meta_ptr, "/%s", curr_dir);

    curr_dir = next_dir;

    res = access(real_path, F_OK);
    if(res == 0) continue;

    res = stat(meta_path, &st);
    if(res == -1) break;

    res = mkdir(real_path, 0755);
    if(res == -1) break;

    res = chmod(real_path, st.st_mode|S_IWUSR);
    if(res == -1) break;

    res = lchown(real_path, st.st_uid, st.st_gid);
    if(res == -1) break;
  }

  if(res == -1) return -1;

  if((real_ptr - real_path + strlen(curr_dir) > MAX_PATH) ||
     (meta_ptr - meta_path + strlen(curr_dir) > MAX_PATH))
  {
    errno = ENAMETOOLONG;
    return -1;
  }

  real_ptr += sprintf(real_ptr, "/%s", curr_dir);
  meta_ptr += sprintf(meta_ptr, "/%s", curr_dir);

  return 0;
}

static int make_path(const char *path, char *real_path, char *meta_path)
{
  struct statvfs stvfs;
  int res;
  int i, count, first, last, step;
  double spaces[MAX_STORAGE], total_space, random_value;

  random_value = ((double)rand()/(double)RAND_MAX);

  spaces[0] = 0.0;
  total_space = 0.0;
  for(i = 1; i < storage.nmounts; ++i)
  {
    res = statvfs(storage.mounts[i], &stvfs);
    if(res == 0 && stvfs.f_bavail > MIN_FREE_BLOCKS)
    {
      total_space += stvfs.f_bavail;
    }
    spaces[i] = total_space;
  }

  if(total_space == 0.0)
  {
    errno = ENOSPC;
    return -1;
  }

  for(i = 1; i < storage.nmounts; ++i)
  {
    spaces[i] /= total_space;
  }

  first = 0;
  last = storage.nmounts - 1;
  count = last;
  while(count > 0)
  {
    i = first; step = count/2; i += step;
    if(spaces[i] < random_value)
    {
      first = ++i;
      count -= step + 1;
    }
    else count = step;
  }
  if(first == 0) first = 1;

  res = make_realdir(path, storage.mounts[first], storage.mounts[0], real_path, meta_path);

  return res;
}

int main(int argc, char *argv[])
{
  int res, len;
  char *config_file;
  char *path;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  storage.nmounts = 0;

  if(argc != 3) return 1;

  config_file = argv[1];
  path = argv[2];

  get_config(config_file);

  len = strlen(storage.mounts[0]);
  if(strncmp(storage.mounts[0], path, len) != 0)
  {
    printf("%s\n", path);
    return 0;
  }

  srand((unsigned)time(NULL));

  path += len;

  if(path[0] != '/') return -1;

  res = make_path(path, real_path, meta_path);
  if(res == -1) return -errno;

  res = symlink(real_path, meta_path);
  if(res == -1) return -errno;

  printf("%s\n", real_path);

  return 0;
}
