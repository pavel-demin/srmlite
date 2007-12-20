#! /bin/sh

# Pick up arguments
hostSrc="$1"
fileSrc="$2"

dirSrc=`dirname $fileSrc`

. url_common.sh

sleep 1

checkFileDel $fileSrc $dirSrc

rm -f $fileSrc
