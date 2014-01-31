#
# Tcl package index file for Starfish remote execution environment
#
# Copyright (c) 2012 Starfish Systems (www.starfishsystems.ca)
# All rights reserved.
#
# This software may be distributed under the terms of the
# GNU General Public License.  A copy of this License has
# been included with the software.  Please see the License
# for warranty and conditions of use.
#

namespace eval starfish {
    set version "1.0"
}

# Define the entire Starfish package.

package ifneeded "starfish"		$starfish::version \
    [list source [file join $dir "pkgStarfish.tcl"]]

# Define the Starfish graphical subpackage.
# Sufficient for graphical managers.

package ifneeded "starfishGui"		$starfish::version \
    [list source [file join $dir "pkgStarfishGui.tcl"]]

# Define the Starfish library subpackage.
# Sufficient for nongraphical managers.

package ifneeded "starfishLib"		$starfish::version \
    [list source [file join $dir "pkgStarfishLib.tcl"]]

# Define just the Starfish base subpackage.
# Sufficient for agents and test managers.

package ifneeded "starfishBase"		$starfish::version \
    [list source [file join $dir "pkgStarfishBase.tcl"]]
