#
# Include the TEA standard macro set
#

builtin(include,tclconfig/tcl.m4)

#
# Add here whatever m4 macros you want to define for your package
#
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
  case x$CC in
  xg++|xgcc)
    GLOBUS_BASE_MODEL="gcc32dbg"
    ;;
  *)
    AC_MSG_ERROR([no ($CC)])
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
          LDFLAGS="-m64 $LDFLAGS"
          ;;
        esac
        ;;
      esac
  ])

  #----------------------------------------------------------------------
  # Checking if the compiler is supported by Globus
  #----------------------------------------------------------------------
  AC_MSG_CHECKING(if compiler supported by globus tools)
  case x$CC in
  xg++|xgcc)
    GLOBUS_MODEL="gcc32dbg"
    ;;
  *)
    AC_MSG_ERROR([no ($CC)])
    ;;
  esac
  case x$enable_64bit in
  xyes) GLOBUS_MODEL="`echo $GLOBUS_MODEL | sed -e 's/32/64/g'`";;
  esac

  CFLAGS="$CFLAGS -I${GLOBUS_DIR}/include/globus -I${GLOBUS_DIR}/include/globus/${GLOBUS_MODEL}"

  AC_MSG_RESULT(yes ($GLOBUS_MODEL))
  AC_SUBST(GLOBUS_MODEL)
])
