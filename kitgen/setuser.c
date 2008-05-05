#include <pwd.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char *argv[]) {

  if(argc < 3) return 1;

  struct passwd *pw = getpwnam(argv[1]);
  if(!pw) return 1;

  if(setgid(pw->pw_gid) || setuid(pw->pw_uid)) return 1;

  return execv(argv[2], argv + 2);
}

