TAR_URL	      = http://www.equi4.com/pub/tk/tars
STARFISH_URL  = http://www.starfishsystems.ca/cgi-bin/download?name=starfish
XOTCL_URL = http://kent.dl.sourceforge.net/sourceforge/xotcl/xotcl-1.6.2.tar.gz

SQLITE_URL    = http://www.sqlite.org/sqlite-3_6_11-tea.tar.gz

OPENSSL_URL   = http://www.openssl.org/source/openssl-0.9.8j.tar.gz
GLOBUS_SRC    = gt4.2.1-all-source-installer
GLOBUS_URL    = http://www-unix.globus.org/ftppub/gt4/4.2.1/installers/src/$(GLOBUS_SRC).tar.gz

TCL_CVS    = :pserver:anonymous@tcl.cvs.sourceforge.net:/cvsroot/tcl
TK_CVS     = :pserver:anonymous@tktoolkit.cvs.sourceforge.net:/cvsroot/tktoolkit
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
	mkdir -p 8.5 && cd 8.5 && \
	  cvs -d $(TCL_CVS) co -r core-8-5-branch tcl && \
	  cvs -d $(TK_CVS) co -r core-8-5-branch tk

tars:
	mkdir -p 8.x && cd 8.x && \
	  wget -q $(TAR_URL)/zlib.tar.gz && \
	  wget -q $(TAR_URL)/vqtcl.tgz && \
	  wget -q $(STARFISH_URL) && \
	  wget -q $(XOTCL_URL) && \
	  wget -q $(SQLITE_URL) && \
	  wget -q $(OPENSSL_URL) && \
	  wget -q $(GLOBUS_URL)

untar:
	mkdir -p 8.x && cd 8.x && \
	  tar xfz zlib.tar.gz && \
	  tar xfz vqtcl.tgz && \
	  tar xfz starfish-0.9.tar.gz && \
	  tar xfz xotcl-1.6.2.tar.gz && \
	  tar xfz sqlite-3_6_11-tea.tar.gz && \
	  tar xfz openssl-0.9.8j.tar.gz && \
	  tar xfz $(GLOBUS_SRC).tar.gz \
	    $(GLOBUS_SRC)/config.guess \
	    $(GLOBUS_SRC)/config.sub \
	    $(GLOBUS_SRC)/configure \
	    $(GLOBUS_SRC)/install-sh \
	    $(GLOBUS_SRC)/Makefile.in \
	    $(GLOBUS_SRC)/gpt \
	    $(GLOBUS_SRC)/source-trees/callout \
	    $(GLOBUS_SRC)/source-trees/common \
	    $(GLOBUS_SRC)/source-trees/core \
	    $(GLOBUS_SRC)/source-trees/gass \
	    $(GLOBUS_SRC)/source-trees/gridftp \
	    $(GLOBUS_SRC)/source-trees/gsi \
	    $(GLOBUS_SRC)/source-trees/io \
	    $(GLOBUS_SRC)/source-trees/mds \
	    $(GLOBUS_SRC)/source-trees/usage \
	    $(GLOBUS_SRC)/source-trees/xio && \
	  mv xotcl-1.6.2 xotcl && \
	  mv sqlite-3_6_11-tea sqlite && \
	  mv openssl-0.9.8j openssl && \
	  mv $(GLOBUS_SRC) globus && \
	  mv starfish-0.9/src/starfish ./ && \
	  mv starfish-0.9/tcl starfish/ && \
	  patch -p 0 < ../globus-export_sec_context.patch && \
	  patch -p 0 < ../starfish-noyp.patch && rm -rf starfish-0.9

configs:
	sh config.sh 8.5/base-std
	sh config.sh 8.5/kit-small cli

small: configs
	cd 8.5/kit-small && $(MAKE)

base tidy:
	for i in 8*/base-*/Makefile; do (cd `dirname $$i`; $(MAKE) $@); done
all clean distclean tclkit-cli tclkit-dyn tclkit-gui:
	for i in 8*/kit-*/Makefile; do (cd `dirname $$i`; $(MAKE) $@); done

.PHONY: all base tidy clean distclean small tars configs
