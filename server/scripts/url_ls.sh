#! /bin/sh

# Pick up arguments
depth="$1"
hostSrc="$2"
fileSrc="$3"

dirSrc=`dirname $fileSrc`

. ./scripts/url_common.sh

checkFileLs $fileSrc $dirSrc

find $fileSrc -maxdepth $depth -exec ls -dlLn --time-style=long-iso {} \;
