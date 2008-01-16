#! /bin/sh

export GLOBUS_TCP_PORT_RANGE=20000,25000
export LD_LIBRARY_PATH=/opt/globus/lib:/opt/glite/lib
export GRIDMAPDIR=/etc/grid-security/gridmapdir
export X509_CERT_DIR=/etc/grid-security/certificates
export X509_VOMS_DIR=/etc/grid-security/vomsdir

./getuser $1
rc=$?
if [ $rc != 0 ]
then
  rm -f $1
  exit $rc
fi

