# Introduction #

This extension provides a binding to Grid Security Infrastructure (GSI), utilizing the Globus GSSAPI and the new Tcl\_StackChannel API for Tcl 8.2 and higher. The sockets behave exactly the same as channels created using Tcl's built-in socket command with additional options for controlling the GSI session.

The following links proved to be extremely helpful while developing this extension:

[How to write a transformation (channel)](http://www.oche.de/~akupries/soft/giot/HOWTO.txt)

[Solaris Security for Developers Guide](http://docs.sun.com/app/docs/doc/816-4863)

[TLS - binding to OpenSSL toolkit](http://www.sensus.org/tcl/tls.htm)


# Details #

The Globus Toolkit provides several layers of abstraction in its IO stack:

| Globus XIO |
|:-----------|
| Globus IO  |
| GSSAPI     |
| GSI        |
| TLS        |
| TCP        |
| IP         |

The developers of the [TclGlobus](http://tclglobus.ligo.caltech.edu/) project encountered some problems with Globus XIO:

http://www-unix.globus.org/mail_archive/discuss/2006/12/msg00018.html

It seems that globus\_xio\_read requires to know in advance the exact number of bytes to be read. For some applications this condition may be too restrictive.

Moreover, Tcl already provides most of the Globus XIO functionality such as asynchronous IO and stackable IO drivers. So, we can bind to GSI at the GSSAPI level and effectively replace XIO services with those from Tcl.