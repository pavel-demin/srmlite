lappend auto_path .

package require g2lite
package require gtlite
package require tdom

package require srmlite::templates
package require srmlite::client
package require srmlite::soap

# -------------------------------------------------------------------------

proc SrmFailed {requestId fileId errorMessage} {

    upvar #0 SrmRequest$requestId request
    upvar #0 SrmFile$fileId file

    set request(state) Failed
    set request(errorMessage) $errorMessage
    set file(state) Failed
}

# -------------------------------------------------------------------------

set requestType get
set fileSURL srm://ingrid-se02.cism.ucl.ac.be:8443/srm/managerv1?SFN=/pnfs/cism.ucl.ac.be/data/cms/sca06/store/PhEDEx_LoadTest07/LoadTest07_Prod_BelgiumUCL/LoadTest07_BelgiumUCL_00

regexp {srm://.*/srm/managerv1} $fileSURL serviceURL

#set serviceURL srm://ingrid-se02.cism.ucl.ac.be:8443/srm/managerv1

SrmCall 1 2 /tmp/x509up_p21624.fileMI7qwX.4 $serviceURL $requestType $fileSURL

vwait forever


