#! /bin/sh

# Pick up arguments
hostDst="$1"
fileDst="$2"

dirDst=`dirname $fileDst`

. ./scripts/url_common.sh

checkFileDst $fileDst $dirDst

result=`./makeFile squirrel.config $fileDst`

touch $result

echo $result
