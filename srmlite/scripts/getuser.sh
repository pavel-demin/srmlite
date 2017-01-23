#! /bin/sh

./getuser $1
rc=$?
if [ $rc != 0 ]
then
  rm -f $1
  exit $rc
fi
