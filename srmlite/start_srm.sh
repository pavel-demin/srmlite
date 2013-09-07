export GLOBUS_TCP_PORT_RANGE=20000,25000
export X509_CERT_DIR=/etc/grid-security/certificates
export X509_VOMS_DIR=/etc/grid-security/vomsdir

./tclkit-cli main.tcl srmlite.cfg
