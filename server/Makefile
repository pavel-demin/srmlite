TDOM_TAG = 0.8.3
XOTCL_TAG = 1.6.8

TDOM_LIB = libtdom$(TDOM_TAG).so
XOTCL_LIB = libxotcl$(XOTCL_TAG).so

TDOM_DIR = tmp/tDOM-$(TDOM_TAG)
XOTCL_DIR = tmp/xotcl-$(XOTCL_TAG)

TDOM_TAR = tmp/tDOM-$(TDOM_TAG).tgz
XOTCL_TAR = tmp/xotcl-$(XOTCL_TAG).tar.gz

TDOM_URL = https://github.com/downloads/tDOM/tdom/tDOM-$(TDOM_TAG).tgz
XOTCL_URL = http://download.sourceforge.net/project/xotcl/xotcl/$(XOTCL_TAG)/xotcl-$(XOTCL_TAG).tar.gz

CFLAGS = -O2 -Wall

OUTDIR = $(shell pwd)/tmp

all: $(TDOM_LIB) $(XOTCL_LIB) getuser putfile g2lite.so gssctx.so

$(TDOM_TAR):
	mkdir -p $(@D)
	curl -L $(TDOM_URL) -o $@

$(XOTCL_TAR):
	mkdir -p $(@D)
	curl -L $(XOTCL_URL) -o $@

$(TDOM_DIR): $(TDOM_TAR)
	tar -mzxf $< --directory=$(@D)

$(XOTCL_DIR): $(XOTCL_TAR)
	tar -mzxf $< --directory=$(@D)

$(TDOM_LIB): $(TDOM_DIR)
	cd $< && sh configure --prefix=$(OUTDIR) --exec-prefix=$(OUTDIR) --with-tcl=/usr/lib64/tcl8.5 && make install-binaries
	cp $(OUTDIR)/lib/tdom$(TDOM_TAG)/$@ $@
	cp $(OUTDIR)/lib/tdom$(TDOM_TAG)/tdom.tcl tdom.tcl

$(XOTCL_LIB): $(XOTCL_DIR)
	cd $< && sh configure --prefix=$(OUTDIR) --exec-prefix=$(OUTDIR) --with-tcl=/usr/lib64/tcl8.5 && make install-binaries
	cp $(OUTDIR)/lib/xotcl$(XOTCL_TAG)/$@ $@

getuser: getuser.c
	gcc $(CFLAGS) -o $@ $^ -lglobus_gss_assist

putfile: putfile.c
	gcc $(CFLAGS) -o $@ $^

g2lite.so: g2lite.c
	gcc -shared -fPIC $(CFLAGS) -o $@ $^

gssctx.so: gssctx.c
	gcc -shared -fPIC $(CFLAGS) -o $@ $^ -lglobus_gssapi_gsi

clean:
	rm -f $(TDOM_LIB) tdom.tcl $(XOTCL_LIB)
	rm -f getuser putfile g2lite.so gssctx.so
	rm -rf tmp
