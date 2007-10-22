TAR_URL	     = http://www.equi4.com/pub/tk/tars
DICT_URL     = http://pascal.scheffers.net/software/tclDict-8.5.2.tar.gz
STARFISH_URL = http://www.starfishsystems.ca/cgi-bin/download?name=starfish

GLOBUS_URL   = http://www-unix.globus.org/ftppub/gt4/4.0/4.0.5/installers/src/gt4.0.5-all-source-installer.tar.gz
GRIDMAP_URL  = http://vdt.cs.wisc.edu/patches/1.8.1/011__gss_assist_gridmap.diff

TCL_CVS    = :pserver:anonymous@tcl.cvs.sourceforge.net:/cvsroot/tcl
TCLX_CVS   = :pserver:anonymous@tclx.cvs.sourceforge.net:/cvsroot/tclx
VFS_CVS    = :pserver:anonymous@tclvfs.cvs.sourceforge.net:/cvsroot/tclvfs
TLS_CVS    = :pserver:anonymous@tls.cvs.sourceforge.net:/cvsroot/tls
TDOM_CVS   = :pserver:anonymous@cvs.tdom.org:/usr/local/pubcvs
TCLLIB_CVS = :pserver:anonymous@tcllib.cvs.sourceforge.net:/cvsroot/tcllib

unspecified-target:

cvs:
	mkdir -p 8.x && cd 8.x && \
	  cvs -d $(TCLX_CVS) co tclx && \
	  cvs -d $(VFS_CVS) co tclvfs && \
	  cvs -d $(TLS_CVS) co tls && \
	  cvs -d ${TDOM_CVS} co tdom && \
	  cvs -d ${TCLLIB_CVS} co tcllib
	mkdir -p 8.4 && cd 8.4 && \
	  cvs -d $(TCL_CVS) co -r core-8-4-branch tcl

tars:
	mkdir -p 8.x && cd 8.x && \
	  wget -q $(TAR_URL)/zlib.tar.gz && tar xfz zlib.tar.gz && \
	  wget -q $(TAR_URL)/vqtcl.tgz && tar xfz vqtcl.tgz && \
	  wget -q $(STARFISH_URL) && tar xfz starfish-0.9.tar.gz && \
	  wget -q $(GLOBUS_URL) && tar xfz gt4.0.5-all-source-installer.tar.gz && \
	  wget -q $(GRIDMAP_URL) && \
	  cd gt4.0.5-all-source-installer/source-trees && \
	  patch -p 2 < ../../011__gss_assist_gridmap.diff && \
	  cd ../.. && rm *gz *diff && \
	  mv gt4.0.5-all-source-installer globus && \
	  mv starfish-0.9/src/starfish ./ && \
	  mv starfish-0.9/tcl starfish/ && \
	  patch -p 0 < ../starfish-noyp.patch && rm -rf starfish-0.9
	mkdir -p 8.4 && cd 8.4 && \
	  wget -q $(DICT_URL) && tar xfz tclDict-8.5.2.tar.gz && \
	  mv tclDict-8.5.2 tclDict && rm *gz

configs:
	sh config.sh 8.4/base-std
	sh config.sh 8.4/kit-small cli

small: configs
	cd 8.4/kit-small && $(MAKE)

base tidy:
	for i in 8*/base-*/Makefile; do (cd `dirname $$i`; $(MAKE) $@); done
all clean distclean tclkit-cli tclkit-dyn tclkit-gui:
	for i in 8*/kit-*/Makefile; do (cd `dirname $$i`; $(MAKE) $@); done

.PHONY: all base tidy clean distclean small tars configs
