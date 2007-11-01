#! /bin/sh

# Pick up arguments
hostSrc="$1"
fileSrc="$2"
hostDst="$3"
fileDst="$4"
certProxy="$5"

dirSrc=`dirname $fileSrc`
dirDst=`dirname $fileDst`

proto="gsiftp"
port=2811

. url_common.sh

checkCertProxy $certProxy

export X509_USER_PROXY="$certProxy"

./globus-url-copy -nodcau -p 8 -tcp-bs 1048576 ${proto}://${hostSrc}:${port}/${fileSrc} ${proto}://${hostDst}:${port}/${fileDst}
