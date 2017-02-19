/*
  gcc -O2 -Wall `pkg-config fuse --cflags --libs` srmlite.c -o srmlite
  strip srmlite
*/

#define FUSE_USE_VERSION 26

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#ifdef linux
/* For pread()/pwrite() */
#define _XOPEN_SOURCE 500
#endif

#include <fuse.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <malloc.h>
#include <pthread.h>
#include <syslog.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/time.h>
#include <sys/fsuid.h>

#define MIN_FREE_BLOCKS 2048000

#define MAX_STORAGE 100

#define MAX_PATH 512

struct
{
  char *mounts[MAX_STORAGE];
  int nmounts;
}
storage;

static pthread_mutex_t exclusive_lock;
static pthread_rwlock_t rw_lock;

static int fsuid = 0;
static int fsgid = 0;
static char *config_file = NULL;

static int xmp_setfsid(void)
{
  struct fuse_context *fc = fuse_get_context();
  setfsuid(fc->uid);
  setfsgid(fc->gid);
  return 0;
}

static int xmp_resetfsid(void)
{
  setfsuid(fsuid);
  setfsgid(fsgid);
  return 0;
}

static void xmp_metapath(const char *path, char *meta_path)
{
  pthread_rwlock_rdlock(&rw_lock);

  snprintf(meta_path, MAX_PATH, "%s/%s", storage.mounts[0], path);

  pthread_rwlock_unlock(&rw_lock);
}

static int xmp_realpath(const char *path, char *real_path, char *meta_path)
{
  int res;
  struct stat stbuf;

  real_path[0] = '\0';
  meta_path[0] = '\0';

  xmp_metapath(path, meta_path);

  res = lstat(meta_path, &stbuf);

  if(res == -1)
    return -1;

  if(S_ISDIR(stbuf.st_mode)) {
    strncpy(real_path, meta_path, MAX_PATH);
    return 1;
  }
  else if(!S_ISLNK(stbuf.st_mode))
    return 0;

  res = readlink(meta_path, real_path, MAX_PATH - 1);

  if(res == -1)
    return -1;

  real_path[res] = '\0';

  return 0;
}

static int xmp_makerealdir(const char *path, const char *real_prfx,
  const char *meta_prfx, char *real_path, char *meta_path)
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

    xmp_resetfsid();

    res = mkdir(real_path, 0755);
    if(res == -1) break;

    res = chmod(real_path, st.st_mode|S_IWUSR);
    if(res == -1) break;

    res = lchown(real_path, st.st_uid, st.st_gid);
    if(res == -1) break;
  }

  if((res == -1) ||
     (real_ptr - real_path + strlen(curr_dir) > MAX_PATH) ||
     (meta_ptr - meta_path + strlen(curr_dir) > MAX_PATH))
  {
    return -1;
  }

  real_ptr += sprintf(real_ptr, "/%s", curr_dir);
  meta_ptr += sprintf(meta_ptr, "/%s", curr_dir);

  return 0;
}

static int xmp_makepath(const char *path, char *real_path, char *meta_path)
{
  int res;
  struct statvfs stvfs;
  int last_ind;
  int curr_ind;
  int counter;
  int found_free_space;

  counter = 0;
  found_free_space = 0;

  pthread_rwlock_rdlock(&rw_lock);

  curr_ind = time(NULL)%(storage.nmounts - 1) + 1;
  last_ind = curr_ind;

  do
  {
    res = statvfs(storage.mounts[curr_ind], &stvfs);

    if(res == -1) continue;

    if(stvfs.f_bavail > MIN_FREE_BLOCKS)
    {
      found_free_space = 1;
      break;
    }

    ++curr_ind;

    if(curr_ind == storage.nmounts) curr_ind = 1;
    if(curr_ind == last_ind) ++counter;

  }
  while (counter < 5);

  if(found_free_space == 0)
  {
    pthread_rwlock_unlock(&rw_lock);
    return -1;
  }

  res = xmp_makerealdir(path, storage.mounts[curr_ind], storage.mounts[0], real_path, meta_path);

  pthread_rwlock_unlock(&rw_lock);

  return res;
}

static int xmp_getattr(const char *path, struct stat *stbuf)
{
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  res = lstat(real_path, stbuf);

  if(res == -1) return -errno;

  return 0;
}

static int xmp_access(const char *path, int mask)
{
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  res = access(real_path, mask);

  if(res == -1) return -errno;

  return 0;
}

static int xmp_readlink(const char *path, char *buf, size_t size)
{
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  res = readlink(real_path, buf, size - 1);

  if(res == -1) return -errno;

  buf[res] = '\0';
  return 0;
}

struct xmp_dirp
{
  DIR *dp;
  struct dirent *entry;
  off_t offset;
};

static int xmp_opendir(const char *path, struct fuse_file_info *fi)
{
  DIR *dp;
  struct xmp_dirp *d;
  char meta_path[MAX_PATH];

  xmp_metapath(path, meta_path);

  dp = opendir(meta_path);

  if(dp == NULL) return -errno;

  d = malloc(sizeof(struct xmp_dirp));
  if(d == NULL)
  {
    closedir(dp);
    return -ENOMEM;
  }

  d->dp = dp;
  d->entry = NULL;
  d->offset = 0;

  fi->fh = (unsigned long) d;
  return 0;
}

static int xmp_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
  off_t offset, struct fuse_file_info *fi)
{
  struct stat st;
  off_t nextoff;
  struct xmp_dirp *d = (struct xmp_dirp *) (uintptr_t) fi->fh;

  (void) path;

  if(offset != d->offset)
  {
    seekdir(d->dp, offset);
    d->entry = NULL;
    d->offset = offset;
  }

  while (1)
  {
    if(!d->entry)
    {
      d->entry = readdir(d->dp);
      if(!d->entry) break;
    }

    memset(&st, 0, sizeof(st));
    st.st_ino = d->entry->d_ino;
    st.st_mode = d->entry->d_type << 12;
    nextoff = telldir(d->dp);

    if(filler(buf, d->entry->d_name, &st, nextoff)) break;

    d->entry = NULL;
    d->offset = nextoff;
  }

  return 0;

}

static int xmp_releasedir(const char *path, struct fuse_file_info *fi)
{
  struct xmp_dirp *d = (struct xmp_dirp *) (uintptr_t) fi->fh;
  (void) path;
  closedir(d->dp);
  free(d);
  return 0;
}

static int xmp_mknod(const char *path, mode_t mode, dev_t rdev)
{
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_makepath(path, real_path, meta_path);

  if(res == -1) return -ENOSPC;

  xmp_setfsid();

  res = mknod(real_path, mode|S_IWUSR, rdev);

  if(res == -1) return -errno;

  res = symlink(real_path, meta_path);

  if(res == -1) return -errno;

  return 0;
}

static int xmp_symlink(const char *from, const char *to)
{
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_makepath(to, real_path, meta_path);

  if(res == -1) return -ENOSPC;

  xmp_setfsid();

  res = symlink(from, real_path);

  if(res == -1) return -errno;

  res = symlink(real_path, meta_path);

  if(res == -1) return -errno;

  return 0;
}

static int xmp_mkdir(const char *path, mode_t mode)
{
  int res;
  char meta_path[MAX_PATH];

  xmp_metapath(path, meta_path);

  xmp_setfsid();

  res = mkdir(meta_path, mode|S_IWUSR);

  if(res == -1) return -errno;

  return 0;
}

static int xmp_unlink(const char *path)
{
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  xmp_setfsid();

  res = unlink(real_path);

  if(res == -1) return -errno;

  res = unlink(meta_path);

  if(res == -1) return -errno;

  return 0;
}

static int xmp_rmdir(const char *path)
{
  int res;
  int i;
  char dir_path[MAX_PATH];

  res = 0;

  xmp_setfsid();

  pthread_rwlock_rdlock(&rw_lock);

  for(i = storage.nmounts - 1; i >= 0; --i)
  {
    snprintf(dir_path, MAX_PATH, "%s/%s", storage.mounts[i], path);
    res = access(dir_path, F_OK);

    if(res == -1)
    {
      res = 0;
      continue;
    }
    res = rmdir(dir_path);

    if(res == -1) break;
  }

  pthread_rwlock_unlock(&rw_lock);

  if(res == -1) return -errno;

  return 0;
}

static int xmp_rename(const char *from, const char *to)
{
  int res;
  char *real_ptr;
  char *meta_ptr;
  char real_to[MAX_PATH];
  char meta_to[MAX_PATH];
  char real_prfx[MAX_PATH];
  char meta_prfx[MAX_PATH];
  char real_from[MAX_PATH];
  char meta_from[MAX_PATH];

  res = xmp_realpath(from, real_from, meta_from);

  if(res == -1) return -ENOENT;

  if(res == 1) return -EISDIR;

  res = xmp_realpath(to, real_to, meta_to);

  xmp_setfsid();

  if(res == 0)
  {
    res = unlink(real_to);

    if(res == -1) return -errno;

    res = unlink(meta_to);
  }

  strncpy(real_prfx, real_from, MAX_PATH);
  real_ptr = strstr(real_prfx, from);
  *real_ptr = '\0';

  strncpy(meta_prfx, meta_from, MAX_PATH);
  meta_ptr = strstr(meta_prfx, from);
  *meta_ptr = '\0';

  res = xmp_makerealdir(to, real_prfx, meta_prfx, real_to, meta_to);

  res = rename(real_from, real_to);
  if(res == -1) return -errno;

  res = unlink(meta_from);
  if(res == -1) return -errno;

  res = symlink(real_to, meta_to);
  if(res == -1) return -errno;

  return 0;
}

static int xmp_chmod(const char *path, mode_t mode)
{
  int i;
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  xmp_setfsid();

  if(res == 1)
  {
    pthread_rwlock_rdlock(&rw_lock);
    for(i = storage.nmounts - 1; i >= 0; --i)
    {
      snprintf(meta_path, MAX_PATH, "%s/%s", storage.mounts[i], path);
      if(access(meta_path, F_OK) == 0)
      {
        res = chmod(meta_path, mode);
        if(res == -1) break;
      }

    }
    pthread_rwlock_unlock(&rw_lock);
  }
  else
  {
    res = chmod(real_path, mode);
  }

  if(res == -1) return -errno;

  return 0;
}

static int xmp_chown(const char *path, uid_t uid, gid_t gid)
{
  int i;
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  xmp_setfsid();

  if(res == 1)
  {
    pthread_rwlock_rdlock(&rw_lock);
    for(i = storage.nmounts - 1; i >= 0; --i)
    {
      snprintf(meta_path, MAX_PATH, "%s/%s", storage.mounts[i], path);
      if(access(meta_path, F_OK) == 0)
      {
        res = lchown(meta_path, uid, gid);
        if(res == -1) break;
      }

    }
    pthread_rwlock_unlock(&rw_lock);

  }
  else
  {
    res = lchown(real_path, uid, gid);
  }

  if(res == -1) return -errno;

  return 0;
}

static int xmp_statfs(const char *path, struct statvfs *stbuf)
{
  static struct statvfs st;
  int bfac;
  int i;
  int res;
  int ret = -1;

  (void) path;

  pthread_rwlock_rdlock(&rw_lock);

  stbuf->f_namemax = 0;
  stbuf->f_bsize =   0;
  stbuf->f_blocks =  0;
  stbuf->f_bavail =  0;
  stbuf->f_bfree =   0;
  stbuf->f_files  =  0;
  stbuf->f_ffree  =  0;

  for(i = 1; i < storage.nmounts; ++i)
  {
    res = statvfs(storage.mounts[i], &st);

    if(res == -1) continue;

    if(st.f_bsize != 32768)
    {
      bfac = 32768/st.f_bsize;

      if(bfac == 0) break;

      st.f_blocks /= bfac;
      st.f_bavail /= bfac;
      st.f_bfree  /= bfac;

      st.f_bsize = 32768;
    }

    stbuf->f_blocks += st.f_blocks;
    stbuf->f_bavail += st.f_bavail;
    stbuf->f_bfree  += st.f_bfree;
    stbuf->f_files  += st.f_files;
    stbuf->f_ffree  += st.f_ffree;

    if(stbuf->f_namemax == 0)
    {
      stbuf->f_namemax = st.f_namemax;
      stbuf->f_bsize = st.f_bsize;
    }

    ret = 0;
  }

  pthread_rwlock_unlock(&rw_lock);
  return ret;
}

static int xmp_utimens(const char *path, const struct timespec ts[2])
{
  int res;
  struct timeval tv[2];
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  xmp_setfsid();

  tv[0].tv_sec = ts[0].tv_sec;
  tv[0].tv_usec = ts[0].tv_nsec / 1000;
  tv[1].tv_sec = ts[1].tv_sec;
  tv[1].tv_usec = ts[1].tv_nsec / 1000;

  res = utimes(real_path, tv);
  if(res == -1) return -errno;

  return 0;
}

static int xmp_open(const char *path, struct fuse_file_info *fi)
{
  int fd;
  int res;
  char real_path[MAX_PATH];
  char meta_path[MAX_PATH];

  res = xmp_realpath(path, real_path, meta_path);

  if(res == -1) return -ENOENT;

  xmp_setfsid();

  fd = open(real_path, fi->flags);

  if(fd == -1) return -errno;

  fi->fh = fd;
  return 0;
}

static int xmp_read(const char *path, char *buf, size_t size, off_t offset,
  struct fuse_file_info *fi)
{
  int res;

  (void) path;
  res = pread(fi->fh, buf, size, offset);
  if(res == -1) res = -errno;

  return res;
}

static int xmp_write(const char *path, const char *buf, size_t size,
  off_t offset, struct fuse_file_info *fi)
{
  int res;

  (void) path;
  res = pwrite(fi->fh, buf, size, offset);
  if(res == -1) res = -errno;

  return res;
}

static int xmp_flush(const char *path, struct fuse_file_info *fi)
{
  int res;
  (void) path;
  res = close(dup(fi->fh));
  if(res == -1) return -errno;
  return 0;
}

static int xmp_release(const char *path, struct fuse_file_info *fi)
{
  (void) path;
  close(fi->fh);
  return 0;
}

static struct fuse_operations xmp_oper = {
  .getattr    = xmp_getattr,
  .access     = xmp_access,
  .readlink   = xmp_readlink,
  .opendir    = xmp_opendir,
  .readdir    = xmp_readdir,
  .releasedir = xmp_releasedir,
  .mknod      = xmp_mknod,
  .symlink    = xmp_symlink,
  .mkdir      = xmp_mkdir,
  .unlink     = xmp_unlink,
  .rmdir      = xmp_rmdir,
  .rename     = xmp_rename,
  .chmod      = xmp_chmod,
  .chown      = xmp_chown,
  .statfs     = xmp_statfs,
  .utimens    = xmp_utimens,
  .open       = xmp_open,
  .read       = xmp_read,
  .write      = xmp_write,
  .flush      = xmp_flush,
  .release    = xmp_release
};

static int
get_config(const char *cfile)
{
  FILE *fp;
  char temp[132];
  char text[132];

  xmp_resetfsid();

  if(!(fp = fopen(cfile, "r")))
  {
    perror("fopen");
    printf("Couldn't open config file: \"%s\"\n", cfile);
    exit(-1);
  }

  storage.nmounts = 1;

  while (fgets(text, 131, fp))
  {
    if(strncmp("storage.metapath", text, 16) == 0)
    {
      sscanf(text, "storage.metapath %s", temp);
      storage.mounts[0] = strdup(temp);
    }
    else if(strncmp("storage.datapath", text, 16) == 0)
    {

      if(storage.nmounts == MAX_STORAGE)
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

  if(!storage.mounts[0])
  {
      printf("No meta mount point defined\n");
      exit(-1);
  }

  if(storage.nmounts < 2)
  {
      printf("No data mount point defined\n");
      exit(-1);
  }

  fflush(NULL);

  return 0;
}

static void sig_handler(int sig)
{
  (void)sig;

  if(pthread_mutex_lock(&exclusive_lock) == EBUSY)
  {
    syslog(LOG_WARNING, "ERROR calling pthread_mutex_lock while in handler, already locked");
    return;
  }

  pthread_rwlock_wrlock(&rw_lock);

  syslog(LOG_INFO, "Received HUP signal, reloading config..\n");

  if(storage.nmounts)
  {
    int i;
    for(i = 0; i < storage.nmounts; ++i)
    {
      if(storage.mounts[i]) free(storage.mounts[i]);
      storage.mounts[i] = (char *)NULL;
    }
    storage.nmounts = 0;
  }

  get_config(config_file);

  pthread_mutex_unlock(&exclusive_lock);
  pthread_rwlock_unlock(&rw_lock);
}

static void set_sig_handler()
{
  struct sigaction sa;

  sa.sa_handler = sig_handler;
  sigemptyset(&(sa.sa_mask));
  sa.sa_flags = 0;

  if(sigaction(SIGHUP, &sa, NULL) == -1)
  {
    perror("Cannot set signal handler");
    _exit(1);
  }
}

int main(int argc, char *argv[])
{
  pthread_mutexattr_t exclusive_attr;
  pthread_mutexattr_settype(&exclusive_attr, PTHREAD_MUTEX_ERRORCHECK);

  pthread_mutex_init(&exclusive_lock, &exclusive_attr);
  pthread_rwlock_init(&rw_lock, NULL);

  fsuid = getuid();
  fsgid = getgid();

  char *new_argv[argc];
  int new_argc = 0;
  int i;
  for(i = 0; i < argc; ++i)
  {
    if(strcmp(argv[i], "-c") == 0)
    {
      config_file = strdup(argv[++i]);
      continue;
    }
    new_argv[new_argc++] = strdup((argv[i]));
  }

  if(!config_file)
  {
    printf("Please, specify config file\n");
    exit(-1);
  }

  openlog("srmlite", LOG_PERROR|LOG_PID, LOG_DAEMON);
  syslog(LOG_INFO, "Starting for uid %d\n", fsuid);

  get_config(config_file);

  set_sig_handler();

  return fuse_main(new_argc, new_argv, &xmp_oper, NULL);
}
