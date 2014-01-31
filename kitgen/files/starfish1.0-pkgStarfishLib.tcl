#
# Tcl package load file for Starfish remote execution environment
#
# Copyright (c) 2012 Starfish Systems (www.starfishsystems.ca)
# All rights reserved.
#
# This software may be distributed under the terms of the
# GNU General Public License.  A copy of this License has
# been included with the software.  Please see the License
# for warranty and conditions of use.
#

package provide starfishLib	$starfish::version

package require starfishBase	$starfish::version

source	[file join [file dirname [info script]] "meta.tcl"]

# Gracefully degrade if the compiled extension is unavailable.
# Callers can detect the missing fuctionality by testing with:
#   [info commands netdb]

load {} starfishLib

namespace eval starfish {
    namespace export	netdb
}
