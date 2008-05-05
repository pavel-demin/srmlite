lappend auto_path .

package require log

package require XOTcl
namespace import ::xotcl::*

package require srmlite::srmv2::client
namespace import ::srmlite::srmv2::client::*

# -------------------------------------------------------------------------

proc SetLogLevel {level} {
    log::lvSuppressLE emergency 0
    log::lvSuppressLE $level 1
    log::lvSuppress $level 0
}

# -------------------------------------------------------------------------

proc FormatLogMessage {level message} {
    set time [clock format [clock seconds] -format {%a %b %d %H:%M:%S %Y}]
    log::Puts $level "\[$time] \[$level\] $message"
}

# -------------------------------------------------------------------------

log::lvCmdForall FormatLogMessage
SetLogLevel debug

set certProxy /tmp/x509up_u1000

set serviceURL srm://maite.iihe.ac.be:8443/srm/managerv2

set serviceURL srm://cmssrm.fnal.gov:8443/srm/managerv2

set serviceURL srm://ccsrm.in2p3.fr:8443/srm/managerv2

#set serviceURL srm://ingrid.cism.ucl.ac.be:8443/srm/managerv2

set srcSURLS [list \
    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/LoadTest07_BelgiumIIHE_00
]

set srcSURLS [list \
    srm://cmssrm.fnal.gov:8443/srm/managerv2?SFN=/11//store/data/2008/2/8/Pass4Skim-TrackerTIF-B2/0000/0ED60A50-47D7-DC11-959B-0017312B5DE9.root
]

set srcSURLS [list \
    srm://ccsrm.in2p3.fr:8443/srm/managerv2?SFN=/pnfs/in2p3.fr/data/cms/import/LoadTest/store/phedex_monarctest/monarctest_IN2P3-DISK1/LoadTest07_IN2P3_06
]

#set srcSURLS [list \
#    srm://ingrid.cism.ucl.ac.be:8443/srm/managerv2?SFN=/opt/work/EventReader.cpp \
#    srm://ingrid.cism.ucl.ac.be:8443/srm/managerv2?SFN=/opt/work/EventReader.hpp
#]

set ::env(X509_USER_PROXY) $certProxy

set output {}

Object callbackRecipient
callbackRecipient proc successCallback {result} {
    global output
    set output $result
}
callbackRecipient proc failureCallback {reason} {
    global output
    set output $reason
}

SrmClient client \
    -serviceURL $serviceURL \
    -SURL $srcSURLS \
    -callbackRecipient ::callbackRecipient

client get

vwait output

puts $output

exit

after 10000

client getDone

vwait output

puts $output

client destroy
callbackRecipient destroy
