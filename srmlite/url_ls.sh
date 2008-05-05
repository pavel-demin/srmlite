#! /bin/sh

# Pick up arguments
depth="$1"
hostSrc="$2"
fileSrc="$3"

dirSrc=`dirname $fileSrc`

. url_common.sh

checkFileLs $fileSrc $dirSrc

find $fileSrc -maxdepth $depth -exec ls -dln --time-style=long-iso {} \;
