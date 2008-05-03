#! /bin/sh

# Pick up arguments
hostSrc="$1"
fileSrc="$2"

dirSrc=`dirname $fileSrc`

. url_common.sh

checkFileLs $fileSrc $dirSrc

find $fileSrc -maxdepth 1 -exec ls -dln --time-style=long-iso {} \;
