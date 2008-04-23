lappend auto_path .

package require XOTcl
namespace import ::xotcl::*

package require srmlite::client
namespace import ::srmlite::client::*

# -------------------------------------------------------------------------

set certProxy /tmp/x509up_u1000

set serviceURL srm://maite.iihe.ac.be:8443/srm/managerv2

set serviceURL srm://cmssrm.fnal.gov:8443/srm/managerv2

set srcSURLS [list \
    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/LoadTest07_BelgiumIIHE_00
]

set srcSURLS [list \
    srm://cmssrm.fnal.gov:8443/srm/managerv2?SFN=/11//store/data/2008/2/8/Pass4Skim-TrackerTIF-B2/0000/0ED60A50-47D7-DC11-959B-0017312B5DE9.root
]

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
    -SURL $srcSURLS \
    -callbackRecipient ::callbackRecipient

client get

vwait output

puts $output

after 10000

client release

vwait output

puts $output

client destroy
callbackRecipient destroy
