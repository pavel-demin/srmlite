TDOM_URL     = https://github.com/downloads/tDOM/tdom/tDOM-0.8.3.tgz
TCLLIB_URL   = http://heanet.dl.sourceforge.net/project/tcllib/tcllib/1.18/tcllib-1.18.tar.gz
ZLIB_URL     = http://heanet.dl.sourceforge.net/project/libpng/zlib/1.2.3/zlib-1.2.3.tar.gz
TCL_URL      = http://heanet.dl.sourceforge.net/project/tcl/Tcl/8.5.19/tcl8.5.19-src.tar.gz
XOTCL_URL    = http://heanet.dl.sourceforge.net/project/xotcl/xotcl/1.6.8/xotcl-1.6.8.tar.gz
STARFISH_URL = http://www.starfishsystems.ca/Share/Source/starfish-1.0.tar.gz
OPENSSL_URL  = http://www.openssl.org/source/openssl-1.0.2j.tar.gz
GLOBUS_SRC   = gt5.2.5-all-source-installer
GLOBUS_URL   = http://toolkit.globus.org/ftppub/gt5/5.2/5.2.5/installers/src/$(GLOBUS_SRC).tar.gz

TCL_CVS      = :pserver:anonymous@tcl.cvs.sourceforge.net:/cvsroot/tcl
VFS_CVS      = :pserver:anonymous@tclvfs.cvs.sourceforge.net:/cvsroot/tclvfs

unspecified-target:

cvs:
	mkdir -p 8.x && cd 8.x && \
	  cvs -d $(VFS_CVS) co tclvfs && \
	  cvs -d $(TCLX_CVS) co tclx

tars:
	mkdir -p 8.5 && cd 8.5 && \
	  curl -LO $(TCL_URL)
	mkdir -p 8.x && cd 8.x && \
	  curl -LO $(ZLIB_URL) && \
	  curl -LO $(STARFISH_URL) && \
	  curl -LO $(XOTCL_URL) && \
	  curl -LO $(TCLLIB_URL) && \
	  curl -LO $(TDOM_URL) && \
	  curl -LO $(OPENSSL_URL) && \
	  curl -LO $(GLOBUS_URL)

untar:
	mkdir -p 8.5 && cd 8.5 && \
	  tar xfz tcl8.5.19-src.tar.gz && \
	  mv tcl8.5.19 tcl
	mkdir -p 8.x && cd 8.x && \
	  tar xfz tDOM-0.8.3.tgz && \
	  tar xfz tcllib-1.18.tar.gz && \
	  tar xfz zlib-1.2.3.tar.gz && \
	  tar xfz xotcl-1.6.8.tar.gz && \
	  tar xfz starfish-1.0.tar.gz && \
	  tar xfz openssl-1.0.2j.tar.gz && \
	  tar xfz $(GLOBUS_SRC).tar.gz \
	    $(GLOBUS_SRC)/config.guess \
	    $(GLOBUS_SRC)/config.site.in \
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
	    $(GLOBUS_SRC)/source-trees/usage \
	    $(GLOBUS_SRC)/source-trees/xio && \
	  mv tDOM-0.8.3 tdom && \
	  mv tcllib-1.18 tcllib && \
	  mv zlib-1.2.3 zlib && \
	  mv xotcl-1.6.8 xotcl && \
	  mv starfish-1.0/src/starfish ./ && \
	  mv starfish-1.0/tcl starfish/ && \
          mv openssl-1.0.0r openssl && \
          mv $(GLOBUS_SRC) globus && \
	  patch -p 0 < ../patches/globus-export_sec_context.patch && \
	  patch -p 0 < ../patches/starfish-noyp.patch && rm -rf starfish-1.0

configs:
	sh config.sh 8.5/base-std
	sh config.sh 8.5/kit-small cli

small: configs
	cd 8.5/kit-small && $(MAKE)

base tidy:
	for i in 8*/base-*/Makefile; do (cd `dirname $$i`; $(MAKE) $@); done

all clean distclean tclkit-clie:
	for i in 8*/kit-*/Makefile; do (cd `dirname $$i`; $(MAKE) $@); done

.PHONY: all base tidy clean distclean small tars configs
