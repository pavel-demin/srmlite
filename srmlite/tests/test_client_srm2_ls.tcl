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

# -------------------------------------------------------------------------

set certProxy /tmp/x509up_u1000

set requestType srmLsRequest

set serviceURL srm://maite.iihe.ac.be:8443/srm/managerv2

#set serviceURL srm://cmssrm.fnal.gov:8443/srm/managerv2

set serviceURL srm://ingrid.cism.ucl.ac.be:8443/srm/managerv2

set serviceURL srm://ccsrm.in2p3.fr:8443/srm/managerv2

#set serviceURL srm://ingrid-se02.cism.ucl.ac.be:8443/srm/managerv1

set srcSURLS [list \
    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/LoadTest07_BelgiumIIHE_00 \
    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/LoadTest07_BelgiumIIHE_01
]
set srcSURLS [list \
    srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/
]

set srcSURLS [list \
    srm://ingrid.cism.ucl.ac.be:8443/srm/managerv2?SFN=/opt/work/EventReader.cpp \
    srm://ingrid.cism.ucl.ac.be:8443/srm/managerv2?SFN=/opt/work/EventReader.xpp
]

#set srcSURLS [list \
#     srm://cmssrm.fnal.gov:8443/srm/managerv2?SFN=/11//store/data/2008/2/8/Pass4Skim-TrackerTIF-B2/0000/0ED60A50-47D7-DC11-959B-0017312B5DE9.root \
#     srm://cmssrm.fnal.gov:8443/srm/managerv2?SFN=/11//store/data/2008/2/8/Pass4Skim-TrackerTIF-B2/0000/04A1BEEA-41D7-DC11-A08F-001731AF68CF.root
#]


set srcSURLS [list \
    srm://ccsrm.in2p3.fr:8443/srm/managerv2?SFN=/pnfs/in2p3.fr/data/cms/data/store/mc/2007/10/19/CSA07-ZeeJets_Pt_1400_1800-1192835597/0005/26DDBA36-4E89-DC11-A2E7-0019B9E4FDCF.root
]

set ::env(X509_USER_PROXY) $certProxy

set query [srmLsReqBody $srcSURLS]

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
    -headers [srmHeaders $requestType]

vwait content

puts $content

request destroy
callbackRecipient destroy
