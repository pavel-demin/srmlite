#! /bin/sh

# Pick up arguments
hostSrc="$1"
fileSrc="$2"

dirSrc=`dirname $fileSrc`

. url_common.sh

checkFileSrc $fileSrc $dirSrc

ls -l $2
