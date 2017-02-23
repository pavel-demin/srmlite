#! /bin/sh

# Pick up arguments
hostSrc="$1"
fileSrc="$2"

fileDst=`readlink $fileSrc`

. ./scripts/url_common.sh

checkFileDel $fileSrc $fileDst

rm -f $fileSrc $fileDst

