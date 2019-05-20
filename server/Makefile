TCL_TAG = 8.6.9
TCLX_TAG = 8.4.1
TDOM_TAG = 0.8.3
XOTCL_TAG = 1.6.8
TCLLIB_TAG = 1.19

OUTDIR = $(shell pwd)/tcl

CFGARGS = --disable-threads --prefix=$(OUTDIR) --exec-prefix=$(OUTDIR)

CFLAGS = -O2 -Wall -I$(OUTDIR)/include

TCL_LIB = $(OUTDIR)/lib/libtcl8.6.so
TCLX_LIB = $(OUTDIR)/lib/tclx8.4/libtclx8.4.so
TDOM_LIB = $(OUTDIR)/lib/tdom$(TDOM_TAG)/libtdom$(TDOM_TAG).so
XOTCL_LIB = $(OUTDIR)/lib/xotcl$(XOTCL_TAG)/libxotcl$(XOTCL_TAG).so
TCLLIB_LIB = $(OUTDIR)/lib/tcllib1.19

TCL_DIR = tmp/tcl$(TCL_TAG)
TCLX_DIR = tmp/tclx8.4
TDOM_DIR = tmp/tDOM-$(TDOM_TAG)
XOTCL_DIR = tmp/xotcl-$(XOTCL_TAG)
TCLLIB_DIR = tmp/tcllib-$(TCLLIB_TAG)

TCL_TAR = tmp/tcl-$(TCL_TAG).tar.gz
TCLX_TAR = tmp/tclx-$(TCLX_TAG).tar.bz2
TDOM_TAR = tmp/tDOM-$(TDOM_TAG).tgz
XOTCL_TAR = tmp/xotcl-$(XOTCL_TAG).tar.gz
TCLLIB_TAR = tmp/tcllib-$(TCLLIB_TAG).tar.gz

TCL_URL = https://sourceforge.net/projects/tcl/files/Tcl/$(TCL_TAG)/tcl$(TCL_TAG)-src.tar.gz
TCLX_URL = https://sourceforge.net/projects/tclx/files/TclX/$(TCLX_TAG)/tclx$(TCLX_TAG).tar.bz2
TDOM_URL = https://github.com/downloads/tDOM/tdom/tDOM-$(TDOM_TAG).tgz
XOTCL_URL = https://sourceforge.net/projects/xotcl/files/xotcl/$(XOTCL_TAG)/xotcl-$(XOTCL_TAG).tar.gz
TCLLIB_URL = https://sourceforge.net/projects/tcllib/files/tcllib/1.19/tcllib-1.19.tar.gz

all: $(TCL_LIB) $(TCLX_LIB) $(TDOM_LIB) $(XOTCL_LIB) $(TCLLIB_LIB) getuser putfile g2lite.so gssctx.so

$(TCL_TAR):
	mkdir -p $(@D)
	curl -L $(TCL_URL) -o $@

$(TCLX_TAR):
	mkdir -p $(@D)
	curl -L $(TCLX_URL) -o $@

$(TDOM_TAR):
	mkdir -p $(@D)
	curl -L $(TDOM_URL) -o $@

$(XOTCL_TAR):
	mkdir -p $(@D)
	curl -L $(XOTCL_URL) -o $@

$(TCLLIB_TAR):
	mkdir -p $(@D)
	curl -L $(TCLLIB_URL) -o $@

$(TCL_DIR): $(TCL_TAR)
	tar -mzxf $< --directory=$(@D)

$(TCLX_DIR): $(TCLX_TAR)
	tar -mjxf $< --directory=$(@D)

$(TDOM_DIR): $(TDOM_TAR)
	tar -mzxf $< --directory=$(@D)
	patch -d tmp -p 0 < patches/tDOM.patch

$(XOTCL_DIR): $(XOTCL_TAR)
	tar -mzxf $< --directory=$(@D)

$(TCLLIB_DIR): $(TCLLIB_TAR)
	tar -mzxf $< --directory=$(@D)

$(TCL_LIB): $(TCL_DIR)
	cd $< && sh unix/configure $(CFGARGS) && make install-binaries install-libraries install-headers

$(TCLX_LIB): $(TCLX_DIR)
	cd $< && sh configure $(CFGARGS) --with-tcl=$(OUTDIR)/lib && make install-binaries install-libraries

$(TDOM_LIB): $(TDOM_DIR)
	cd $< && sh configure $(CFGARGS) --with-tcl=$(OUTDIR)/lib && make install-binaries install-libraries

$(XOTCL_LIB): $(XOTCL_DIR)
	cd $< && sh configure $(CFGARGS) --with-tcl=$(OUTDIR)/lib && make install-binaries install-libraries

$(TCLLIB_LIB): $(TCLLIB_DIR)
	cd $< && sh configure $(CFGARGS) --with-tcl=$(OUTDIR)/lib && make install-libraries

getuser: getuser.c
	gcc $(CFLAGS) -o $@ $^ -lglobus_gss_assist

putfile: putfile.c
	gcc $(CFLAGS) -o $@ $^

g2lite.so: g2lite.c
	gcc -shared -fPIC $(CFLAGS) -o $@ $^

gssctx.so: gssctx.c
	gcc -shared -fPIC $(CFLAGS) -o $@ $^ -lglobus_gssapi_gsi

clean:
	rm -f getuser putfile g2lite.so gssctx.so
	rm -rf tcl tmp
