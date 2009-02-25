package ifneeded tls 1.6 [list tls_load $dir]

proc tls_load {dir} {
    load "" tls
    source [file join $dir tls.tcl]
    rename tls_load {}
}
