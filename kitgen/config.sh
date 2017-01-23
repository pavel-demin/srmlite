#set -x

args="$*"

verbose=0; case $1 in -v) verbose=1; shift ;; esac

root=`dirname $1`
base=`basename $1`
shift

case $root in .) root=8.4;; esac
path=$root/$base
  
if test ! -d $root
  then echo "error: directory '$root' does not exist"; exit 1; fi

for v in allenc allmsgs cli tzdata
  do eval $v=0; done

while test $# != 0
  do eval $1=1; shift; done

make=$path/Makefile
mach=`uname`
plat=unix

echo "Configuring $make for $mach."
mkdir -p $path

cli=1

( echo "# Generated `date`:"
  echo "#   `basename $0` $args"
  echo
  
  case $mach in
  
    Linux)
      echo "LDFLAGS    = -ldl -lm -lltdl"
      case $b64 in 1)
        echo "CFLAGS     += -m64" ;; 
      esac
      ;;

    *BSD)
      echo "LDFLAGS    = -lm"
      case $b64 in 1)
        echo "CFLAGS     += -m64" ;; 
      esac
      ;;

    SunOS)
      echo "LDFLAGS    = -ldl -lsocket -lnsl -lm"
      ;;

    *) echo "warning: no settings known for '$mach'" >&2 ;;
  esac

  echo "PLAT       = $plat"
  case $plat in unix)
    echo "PRIV       = install-headers install-private-headers" ;;
  esac
  case $b64 in 1)
    echo "TCL_OPTS   += --enable-64bit" 
    echo "VFS_OPTS   += --enable-64bit" 
  esac

  case $allenc  in 1) kitopts="$kitopts -e" ;; esac
  case $allmsgs in 1) kitopts="$kitopts -m" ;; esac
  case $tzdata  in 1) kitopts="$kitopts -z" ;; esac
  
  case $tzdata in 1) echo "TCL_OPTS  += --with-tzdata" ;; esac

  case $cli in 1) targets="$targets tclkit-cli" ;; esac

  echo
  echo "include ../../makefile.include"
  
) >$make

case $verbose in 1)
  echo
  echo "Contents of $make:"
  echo "======================================================================="
  cat $make
  echo "======================================================================="
  echo
  echo "To build, run these commands:"
  echo "    cd $path"
  echo "    make"
  echo
  echo "This produces the following executable(s):"
  case $cli in 1) echo "    $path/tclkit-cli   (command-line)" ;; esac
  echo
  echo "To remove all intermediate builds, use 'make clean'."
  echo "To remove all executables as well, use 'make distclean'."
  echo
esac
