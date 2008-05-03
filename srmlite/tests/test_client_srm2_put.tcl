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

#set serviceURL srm://cmssrm.fnal.gov:8443/srm/managerv2

set serviceURL srm://ingrid-se01.cism.ucl.ac.be:8443/srm/managerv2

set dstSURLS [list \
    srm://ingrid-se01.cism.ucl.ac.be:8443/srm/managerv2?SFN=/storage/data/test/test_1/abc_6.root
]

#set dstSURLS [list \
#    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/abc_123.root
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
    -fileId 1234 \
    -serviceURL $serviceURL \
    -SURL $dstSURLS \
    -size 1000 \
    -callbackRecipient ::callbackRecipient

client put

vwait output

puts $output

exit

after 10000

client release

vwait output

puts $output

client destroy
callbackRecipient destroy
