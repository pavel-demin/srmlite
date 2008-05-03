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

set certProxy /tmp/x509up_u1000

set serviceURL srm://maite.iihe.ac.be:8443/srm/managerv2

set serviceURL srm://cmssrm.fnal.gov:8443/srm/managerv2

#set serviceURL srm://ingrid-se01.cism.ucl.ac.be:8443/srm/managerv2

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

set query [srmPingReqBody]
set requestType srmPing

HttpRequest request \
    -url $serviceURL \
    -agent Axis/1.3 \
    -accept {application/soap+xml, application/dime, multipart/related, text/*} \
    -type {text/xml; charset=utf-8} \
    -callbackRecipient ::callbackRecipient

request send \
    -query $query \
    -headers [srmHeaders $requestType]

vwait output

puts $output

request destroy
callbackRecipient destroy
