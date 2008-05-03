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

set requestType srmMkdir

set serviceURL srm://maite.iihe.ac.be:8443/srm/managerv2

set SURL srm://maite.iihe.ac.be:8443/srm/managerv2?SFN=/pnfs/iihe/cms/ph/sc4/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumIIHE/

set ::env(X509_USER_PROXY) $certProxy

set query [srmMkdirReqBody $SURL]

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
