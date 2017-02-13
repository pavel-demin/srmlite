package require log

namespace eval ::srmlite::utilities {

    variable ftpHosts
    set ftpHosts [list]

# -------------------------------------------------------------------------

    variable logFileId
    set logFileId {}

# -------------------------------------------------------------------------

    variable uniqueId
    set uniqueId   -2147483648

# -------------------------------------------------------------------------

    variable permDict
    set permDict {
        rwx 7
        rws 7
        rw- 6
        r-x 5
        r-s 5
        r-- 4
        -wx 3
        -ws 3
        -w- 2
        --x 1
        --s 1
        --- 0
        - {}
        + {}
        d {}
        l {}
        p {}
        s {}
        t {}
    }

# -------------------------------------------------------------------------

    variable permArray
    array set permArray {
        0 NONE
        1 X
        2 W
        3 WX
        4 R
        5 RX
        6 RW
        7 RWX
    }

# -------------------------------------------------------------------------

    proc NewUniqueId {} {

        variable uniqueId

        return [incr uniqueId]
    }

# -------------------------------------------------------------------------

    proc ExtractFileType {mode} {
        set fileType [string index $mode 0]
        if {$fileType eq {d}} {
            return DIRECTORY
        } elseif {$fileType eq {l}} {
            return LINK
        } else {
            return FILE
        }
    }

# -------------------------------------------------------------------------

    proc ExtractOwnerMode {mode} {
        variable permDict
        variable permArray
        set permMode [string map $permDict $mode]
        return $permArray([string index $permMode 0])
    }

# -------------------------------------------------------------------------

    proc ExtractGroupMode {mode} {
        variable permDict
        variable permArray
        set permMode [string map $permDict $mode]
        return $permArray([string index $permMode 1])
    }

# -------------------------------------------------------------------------

    proc ExtractOtherMode {mode} {
        variable permDict
        variable permArray
        set permMode [string map $permDict $mode]
        return $permArray([string index $permMode 2])
    }

# -------------------------------------------------------------------------

    proc ExtractHostPortFile {url} {
        set exp {^(([^:]*)://)?([^@]+@)?([^/:]+)(:(\d+))?(/srm/managerv\d[^/]*)?(/.*)?$}
        if {![regexp -nocase $exp $url x prefix proto user host y port z file]} {
            log::log error "Unsupported URL $url"
            return {}
        }

        set file [file normalize $file]
        return [list $host $port $file]
    }

# -------------------------------------------------------------------------

    proc TransferHost {} {
        variable ftpHosts

        # round robin scheduling
        set host [lindex $ftpHosts 0]
        set ftpHosts [lreplace $ftpHosts 0 0]
        lappend ftpHosts $host

        return $host
    }

# -------------------------------------------------------------------------

    proc ConvertSURL2TURL {url} {

        set file [lindex [ExtractHostPortFile $url] 2]

        return "gsiftp://[TransferHost]:2811/$file"
    }

# -------------------------------------------------------------------------

    proc LogRotate {file} {
        variable logFileId

        log::log debug "LogRotate"

        if {[catch {file size $file} result]} {
            log::log error $result
            return
        }

        if {$result < 200000000} {
            return
        }

        set fid $logFileId
        set channels [file channels $fid]
        if {$channels ne {}} {
            close $fid

            file rename -force $file $file.old

            set fid [open $file w]
            chan configure $fid -blocking 0 -buffering line
            log::lvChannelForall $fid
            set logFileId $fid
        }
    }

# -------------------------------------------------------------------------

    namespace export NewUniqueId ExtractFileType ExtractOwnerMode \
        ExtractGroupMode ExtractOtherMode ExtractHostPortFile TransferHost \
        ConvertSURL2TURL LogRotate
}

package provide srmlite::utilities 0.1
