#!/bin/sh

# remove installed libs
rm -f /usr/lib64/libXrdSecgsiAuthzPEP*

# compile src
gcc  -fPIC -g -c -Wall -I/usr/include/xrootd -I/usr/include/globus -I. \
     -I/usr/lib64/globus/include XrdSecgsiAuthzFunPEP.cc

gcc  -fPIC -g -c -Wall -I/usr/include/globus -I/usr/lib64/globus/include \
     -I/usr/src/debug/argus-gsi-pep-callout-1.2.2/src xrd_pep_callout.c 

# link opbjects and libs and create lib
gcc -shared -Wl,-soname,libXrdSecgsiAuthzPEP.so.1 \
    -o libXrdSecgsiAuthzPEP.so.1.0.0 xrd_pep_callout.o XrdSecgsiAuthzFunPEP.o \
    -lgsi_pep_callout -lXrdSecgsi

# install lib
mv libXrdSecgsiAuthzPEP.so.1.0.0 /usr/lib64/.
ldconfig
ln -s /usr/lib64/libXrdSecgsiAuthzPEP.so.1.0.0 /usr/lib64/libXrdSecgsiAuthzPEP.so

#clean all
rm -f XrdSecgsiAuthzFunPEP.o xrd_pep_callout.o
