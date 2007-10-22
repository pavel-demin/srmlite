#
# Tcl package load file for Starfish remote execution environment
#
# Copyright (c) 2003 Starfish Systems (www.starfishsystems.ca)
# All rights reserved.
#
# This software may be distributed under the terms of the
# GNU General Public License.  A copy of this License has
# been included with the software.  Please see the License
# for warranty and conditions of use.
#

package provide starfishBase	$starfish::version

source	[file join [file dirname [info script]] "conn.tcl"]
source	[file join [file dirname [info script]] "misc.tcl"]
