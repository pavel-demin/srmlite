lappend auto_path .

package require g2lite
package require log

package require XOTcl
namespace import ::xotcl::*

package require srmlite::gridftp
namespace import ::srmlite::gridftp::*

# -------------------------------------------------------------------------

set certProxy /tmp/x509up_u1000

set srcTURL gsiftp://cmsstor23.fnal.gov:2811///WAX/11/store/data/2008/2/8/Pass4Skim-TrackerTIF-B2/0000/0ED60A50-47D7-DC11-959B-0017312B5DE9.root
set dstTURL gsiftp://ingrid-se01.cism.ucl.ac.be:2811/storage/data/test/test_1/abc_3.root

set ::env(X509_USER_PROXY) $certProxy

Object callbackRecipient
callbackRecipient proc successCallback {result} {
    global content
    set content $result
    puts "Asynchronous request suceeded!"
}
callbackRecipient proc failureCallback {reason} {
    global content
    set content {}
    puts "Asynchronous request failed: $reason"
}

GridFtpTransfer transfer \
    -fileId 1234 \
    -srcTURL $srcTURL \
    -dstTURL $dstTURL \
    -callbackRecipient ::callbackRecipient

puts 1
transfer start
puts 2

vwait content

puts $content

transfer destroy
callbackRecipient destroy
