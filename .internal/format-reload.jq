# format-reload.jq -- recognize and render the proxy's rules hot-reload lines.
#
# Emits the display line when the input is a reload line, else empty -- the caller
# falls through to format-misc.jq on empty. Two flavors:
#
#   reloaded   "[script] rules reloaded  @ time" -- routine, just visible enough to
#              confirm an edit took effect.
#   failed     "[script] RULES RELOAD FAILED (previous rules kept)  <error>  @ time"
#              -- loud like a DENY: the user's edit did NOT take effect, and the proxy
#              keeps enforcing the previous rules.
#
# The msg strings matched here are emitted by .internal/proxy/main.go (reloadIfChanged);
# keep the two in sync.
#
# Inputs:
#   $script         (string) the proxy script's name, tagging the synthesized line

include "util";

(try fromjson catch null) as $entry
| if ($entry | type) != "object" then empty
  elif $entry.msg == "egress ACL reloaded"
  then "[" + $script + "] rules reloaded  @ " + field($entry.time)
  elif $entry.msg == "egress ACL reload failed; keeping the previous rules"
  then "[" + $script + "] RULES RELOAD FAILED"
       + " (previous rules kept)  " + field($entry.error)
       + "  @ " + field($entry.time)
  else empty
  end
