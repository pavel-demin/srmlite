lappend auto_path .

package require g2lite
package require tdom
package require log

package require srmlite::templates
package require srmlite::soap

package require XOTcl
namespace import ::xotcl::*

package require srmlite::http
namespace import ::srmlite::http::*

# -------------------------------------------------------------------------

set certProxy /tmp/x509up_u1000

set requestType srmLsRequest

set serviceURL srm://maite.iihe.ac.be:8443/srm/managerv2

#set serviceURL srm://cmssrm.fnal.gov:8443/srm/managerv2

#set serviceURL srm://ingrid.cism.ucl.ac.be:8443/srm/managerv2

#set serviceURL srm://ingrid-se01.cism.ucl.ac.be:8444/srm/managerv2
#set serviceURL srm://ingrid-se02.cism.ucl.ac.be:8443/srm/managerv1

set srcSURLS [list \
    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/LoadTest07_BelgiumIIHE_00 \
    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/LoadTest07_BelgiumIIHE_01
]

#set srcSURLS [list \
#     srm://cmssrm.fnal.gov:8443/srm/managerv2?SFN=/11//store/data/2008/2/8/Pass4Skim-TrackerTIF-B2/0000/0ED60A50-47D7-DC11-959B-0017312B5DE9.root \
#     srm://cmssrm.fnal.gov:8443/srm/managerv2?SFN=/11//store/data/2008/2/8/Pass4Skim-TrackerTIF-B2/0000/04A1BEEA-41D7-DC11-A08F-001731AF68CF.root
#]


set ::env(X509_USER_PROXY) $certProxy

set query [Srm2LsBody $srcSURLS]

puts $query

set content {}

Object instproc log msg {
  puts "$msg, [self] [self callingclass]->[self callingproc]"
}

Object callbackRecipient
callbackRecipient proc successCallback {result} {
    global content
    set content $result
    my log "Asynchronous request suceeded!"
}
callbackRecipient proc failureCallback {reason} {
    global content
    set content {}
    my log "Asynchronous request failed: $reason"
}

HttpRequest request \
    -url $serviceURL \
    -agent Axis/1.3 \
    -accept {application/soap+xml, application/dime, multipart/related, text/*} \
    -type {text/xml; charset=utf-8} \
    -callbackRecipient ::callbackRecipient

request send \
    -query $query \
    -headers [SrmHeaders $requestType]

vwait content

puts $content

request destroy
callbackRecipient destroy
