#! /bin/sh

# Pick up arguments
hostSrc="$1"
fileSrc="$2"

dirSrc=`dirname $fileSrc`

. ./scripts/url_common.sh

checkFileSrc $fileSrc $dirSrc

ls -lL --time-style=long-iso $fileSrc
