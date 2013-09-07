#! /bin/sh

# Pick up arguments
hostDst="$1"
fileDst="$2"

dirDst=`dirname $fileDst`

. ./url_common.sh

checkFileDst $fileDst $dirDst

# touch $fileDst
