#! /bin/sh

# Pick up arguments
hostDst="$1"
fileDst="$2"

dirDst=`dirname $fileDst`

. ./scripts/url_common.sh

checkFileDst $fileDst $dirDst

result=`./putfile storage.cfg $fileDst`

rc=$?
if [ $rc != 0 ]
then
  echo "Failed to put $fileDst"
  exit $rc
fi

touch $result

echo $result
