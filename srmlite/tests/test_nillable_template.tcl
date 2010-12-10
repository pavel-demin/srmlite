package require g2lite

package require XOTcl
namespace import ::xotcl::*

# -------------------------------------------------------------------------

Class Request -parameter {
        requestStateComment
    }

# -------------------------------------------------------------------------

proc nillableValue {tag var} {
  variable g2result
  upvar $var value
  if {[info exists value]} {
      append g2result {>} $value {</} $tag
  } else {
      append g2result { xsi:nil="true"/}
  }
}

# -------------------------------------------------------------------------

proc InitTemplateNillable {} {

  set fid [open test_nillable_template.xml]
  set content [read $fid]
  close $fid

  proc TestNillable {request} [g2lite $content]
}

InitTemplateNillable

Request req

puts [TestNillable req]


