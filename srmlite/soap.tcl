# -------------------------------------------------------------------------
#
# Copyright (C) 2001 Pat Thoyts <patthoyts@users.sourceforge.net>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
# ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# Except as contained in this notice, the name of the author shall not be used
# in advertising or otherwise to promote the sale, use or other dealings in
# this Software without prior written authorization from the author.
#
# -------------------------------------------------------------------------

package require tdom

# -------------------------------------------------------------------------

# Description:
#   Return a list of all the immediate children of domNode that are element
#   nodes.
# Parameters:
#   node - a reference to a node in a dom tree
#
proc SoapElements {node} {
    set result {}
    foreach childNode [$node childNodes] {
        if {[$childNode nodeType] == {ELEMENT_NODE}} {
            lappend result $childNode
        }
    }
    return $result
}

# -------------------------------------------------------------------------

proc SoapElementNames {node} {
    set result {}
    set elementNodes [SoapElements $node]
    if {$elementNodes eq {}} {
        set result [$node nodeName]
    } else {
        foreach element $elementNodes {
            lappend result [$element nodeName]
        }
    }
    return $result
}

# -------------------------------------------------------------------------

# for extracting the parameters from a SOAP packet.
# Arrays -> list
# Structs -> list of name/value pairs.
# a methods parameter list comes out looking like a struct where the member
# names == parameter names. This allows us to check the param name if we need
# to.
#
proc SoapIsArray {node} {
    # Look for "xsi:type"="soapenc:Array"
    # FIX ME
    # This code should check the namespace using namespaceURI code (CGI)
    #

    if {[$node hasAttribute soapenc:arrayType]} {
        return 1
    }

    if {[$node hasAttribute xsi:type]} {
        set type [$node getAttribute xsi:type]
        if {[string match -nocase {*:Array} $type]} {
            return 1
        }
    }

    if {[$node hasAttribute xsi:type]} {
        set type [$node getAttribute xsi:type]
        if {[string match -nocase {*:ArrayOf*} $type]} {
            return 1
        }
    }

    # If all the child element names are the same, it's an array
    # but of there is only one element???
    set names [SoapElementNames $node]
    if {[llength $names] > 1 && [llength [lsort -unique $names]] == 1} {
        return 1
    }

    set name [$node nodeName]
    if {[string match -nocase {arrayOf*} $name]} {
        return 1
    }

    return 0
}

# -------------------------------------------------------------------------

# Description:
#   Merge together all the child node values under a given dom element
#   This procedure will also cope with elements whose data is elsewhere
#   using the href attribute. We currently expect the data to be a local
#   reference.
# Params:
#   node - a reference to an element node in a dom tree
# Result:
#   A string containing the elements value
#
proc SoapElementValue {node} {
    set result {}

    if {[$node hasAttribute href]} {
        set href [$node getAttribute href]
        if {[string match "\#*" $href]} {
            set href [string trimleft $href "\#"]
        } else {
            return -code error "cannot follow non-local href"
        }
        set ns {soap http://schemas.xmlsoap.org/soap/envelope/}
        append path {/soap:Envelope/soap:Body/*[@id='} $href {']}

        set result [SoapDecompose [$node selectNodes -namespaces $ns $path]]
    } else {
        foreach dataNode [$node childNodes] {
            append result [$dataNode nodeValue]
        }
    }

    return $result
}

# -------------------------------------------------------------------------

# Description:
#   Break down a SOAP packet into a Tcl list of the data.
#
proc SoapDecompose {node} {
    set result {}

    # get a list of the child elements of this base element.
    set elementNodes [SoapElements $node]

    # if no child element - return the value.
    if {$elementNodes eq {}} {
        set result [SoapElementValue $node]
    } else {
        # decide if this is an array or struct
        if {[SoapIsArray $node]} {
            foreach element $elementNodes {
                lappend result [SoapDecompose $element]
            }
        } else {
            foreach element $elementNodes {
                lappend result [$element nodeName] [SoapDecompose $element]
            }
        }
    }

    return $result
}

# -------------------------------------------------------------------------

package provide srmlite::soap 0.1
