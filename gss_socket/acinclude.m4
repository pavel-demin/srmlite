dnl =====================================================================
dnl   Search for GLOBUS header files
dnl =====================================================================
AC_DEFUN([SG_CHECK_GLOBUS_HEADER],
[
  case x${with_globus} in
  x|xno)
    ;;
  *)
    hdr="globus_$1.h"
    AC_MSG_CHECKING(if globus has $hdr)
    if test -f ${with_globus}/include/${GLOBUS_BASE_MODEL}/$hdr
    then
      AC_DEFINE(HAVE_GLOBUS_$2_H,1,Set to 1 if globus installation has globus_$1.h header)
      AC_MSG_RESULT(yes)
      AM_CONDITIONAL(HAVE_GLOBUS_$2,true)
      AC_MSG_CHECKING(if globus has $hdr in threaded model)
      if test -f ${with_globus}/include/${GLOBUS_BASE_MODEL}pthr/$hdr
      then
        AC_MSG_RESULT(yes)
      else
        AC_MSG_RESULT(no)
	default_globus_thread_model=""
      fi
   else
      AM_CONDITIONAL(HAVE_GLOBUS_$2,false)
      AC_MSG_RESULT(no)
    fi
    ;;
  esac
]
)
dnl =====================================================================
dnl   Search for GLOBUS
dnl =====================================================================
AC_DEFUN([SG_PACKAGE_GLOBUS],
[
  AC_ARG_WITH([globus],
  [  --with-globus=<dir>   top level directory containing GLOBUS tools],
  [ case x${with_globus} in
    x|xno)
      AC_MSG_ERROR(Cannot build without GLOBUS tool set)
      ;;
    esac
  ],[
    dnl------------------------------------------------------------------
    dnl Default handler
    dnl------------------------------------------------------------------
    dnl   Making an educatecd guess where the tools are installed
    dnl   The sed expression will look in the user's path for
    dnl     additional directories to try.
    dnl -----------------------------------------------------------------
    for path in ${GLOBUS_LOCATION} ${prefix} `echo $PATH | \
      sed -e 's,/s*bin:, ,g' -e 's/:/ /g' -e 's,/s*bin$,,'`
    do
      if test -x $path/bin/globus-makefile-header
      then
        with_globus="$path"
	break
      fi
    done
  ]) dnl AC_ARG_WITH
  AC_MSG_CHECKING(for globus installation directory)
  if test -d "${with_globus}"
  then
    AC_MSG_RESULT(${with_globus})
    GLOBUS_DIR="${with_globus}"
    AC_SUBST(GLOBUS_DIR)
  else
    AC_MSG_RESULT(FAILED)
    AC_MSG_ERROR(unable to find GLOBUS. Please set the env variable GLOBUS_LOCATION)
  fi
  #----------------------------------------------------------------------
  # Checking if the compiler is supported by Globus
  #----------------------------------------------------------------------
  AC_MSG_CHECKING(if compiler supported by globus tools)
  case x$CXX in
  xg++|xgcc)
    GLOBUS_BASE_MODEL="gcc32dbg"
    ;;
  *)
    AC_MSG_ERROR([no ($CXX)])
    ;;
  esac
  AC_MSG_RESULT(yes)
  AC_ARG_ENABLE([64bit],
    [  --enable-64bit   turns on special flags for building 64bit binaries],
    [ GLOBUS_BASE_MODEL="`echo $GLOBUS_BASE_MODEL | sed -e 's/32/64/g'`"
      case x$CC in
      xgcc)
        case `uname -m` in
	ia64)
	  # By default this system builds 64 bit
	  ;;
	*)
          CFLAGS="$CFLAGS -m64"
          CXXFLAGS="$CXXFLAGS -m64"
          LDFLAGS="-m64 $LDFLAGS"
          ;;
        esac
        ;;
      esac
  ])
  #----------------------------------------------------------------------
  # Check for header files
  #  If any of the header files needed do not have a threaded counter
  #  part, then default_globus_thread_model will be set to the empty
  #  string.
  #----------------------------------------------------------------------
  default_globus_thread_model="pthr"

  SG_CHECK_GLOBUS_HEADER(common,COMMON)
  SG_CHECK_GLOBUS_HEADER(common_include,COMMON_INCLUDE)
  SG_CHECK_GLOBUS_HEADER(error,ERROR)
  SG_CHECK_GLOBUS_HEADER(gss_assist,GSS_ASSIST)
  #----------------------------------------------------------------------
  # Checking for Globus Thread support
  #----------------------------------------------------------------------
  AC_MSG_CHECKING(for globus threads)
  AC_ARG_ENABLE([globus-threads],
  [  --enable-globus-threads   model of GLOBUS threading],
  [ case x${enable_globus_threads} in
    xyes)
      globus_threads="pthr"
      case x${default_globus_thread_model} in
      x)
        AC_MSG_ERROR(cannot enable globus threads because not all packages support the threaded model)
	;;
      esac
      ;;
    xno)
      globus_threads=""
      ;;
    esac
  ],[
    dnl------------------------------------------------------------------
    dnl Default handler
    dnl------------------------------------------------------------------
    globus_threads=${default_globus_thread_model}
  ])
  case x$globus_threads in
  x)
    AC_MSG_RESULT(<none>)
    ;;
  *)
    AC_MSG_RESULT($globus_threads)
    AC_DEFINE(HAVE_GLOBUS_THREADED,1,true if globus compiled with threads)
    ;;
  esac
  #----------------------------------------------------------------------
  # Checking if the compiler is supported by Globus
  #----------------------------------------------------------------------
  AC_MSG_CHECKING(if compiler supported by globus tools)
  case x$CXX in
  xg++|xgcc)
    GLOBUS_MODEL="gcc32dbg${globus_threads}"
    ;;
  *)
    AC_MSG_ERROR([no ($CXX)])
    ;;
  esac
  case x$enable_64bit in
  xyes) GLOBUS_MODEL="`echo $GLOBUS_MODEL | sed -e 's/32/64/g'`";;
  esac

  AC_MSG_RESULT(yes ($GLOBUS_MODEL))
  AC_SUBST(GLOBUS_MODEL)
  AC_ARG_ENABLE([globus-experimental])
  AC_MSG_CHECKING(if globus experimental modules should be built)
  case x$enable_globus_experimental in
  xyes)
    AC_MSG_RESULT(yes)
    AM_CONDITIONAL(ENABLE_GLOBUS_EXPERIMENTAL,true)
    ;;
  *)
    AC_MSG_RESULT(no)
    AM_CONDITIONAL(ENABLE_GLOBUS_EXPERIMENTAL,false)
    ;;
  esac
])
