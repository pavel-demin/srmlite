#! /bin/sh

# Pick up arguments
hostDst="$1"
fileDst="$2"

. ./url_common.sh

checkDirDel $fileDst

rmdir $fileDst

