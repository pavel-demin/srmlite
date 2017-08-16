#! /bin/sh

# Pick up arguments
hostSrc="$1"
fileSrc="$2"

if [ -L "$fileSrc" ]
then
  fileDst=`readlink $fileSrc`
else
  fileDst=$fileSrc
fi

. ./scripts/url_common.sh

checkFileDel $fileSrc $fileDst

rm -f $fileSrc $fileDst

