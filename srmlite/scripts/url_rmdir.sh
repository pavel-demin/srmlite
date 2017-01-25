#! /bin/sh

# Pick up arguments
hostDst="$1"
fileDst="$2"

. ./scripts/url_common.sh

checkDirDel $fileDst

rmdir $fileDst

