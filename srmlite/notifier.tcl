package require XOTcl

namespace eval ::srmlite::notifier {
  namespace import ::xotcl::*

    Class Notifier -parameter {
       {callbackRecipient}
    }

    Notifier instproc notify {method arg} {
        if {[my exists callbackRecipient]} {
            after 0 [list [my callbackRecipient] $method $arg]
        }
    }

    namespace export Notifier
}

package provide srmlite::notifier 0.1
