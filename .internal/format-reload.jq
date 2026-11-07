# format-reload.jq -- recognize and render the proxy's hot-reload lines: of the rules, and of the
# GitHub allowlist, which the relays serve.
#
# Emits the display line when the input is a reload line, else empty -- the caller
# falls through to format-misc.jq on empty. Two flavors of each:
#
#   reloaded   "[script] rules reloaded  @ time" -- always plain: routine, just visible
#              enough to confirm an edit took effect.
#   failed     "[script] RULES RELOAD FAILED (previous rules kept)  <error>  @ time"
#              -- loud like a DENY (ANSI-red marker + BEL when interactive): the user's
#              edit did NOT take effect, and the proxy keeps enforcing the previous rules.
#
# The msg strings matched here are emitted by .internal/proxy/main.go (its *Reloaded and
# *ReloadFailed constants),
# and classify_log (.internal/classify-log.sh) matches them on the raw line to fire its
# reload hook; keep all three in sync.
#
# Inputs:
#   $is_interactive (bool)   colorize the failure marker and prefix the BEL
#   $script         (string) the proxy script's name, tagging the synthesized line

include "util";

def bell: if $is_interactive then bel else "" end;

# Render the reload entry given as input, of WHAT, and of its failure, which keeps the previous KEPT.
def reloaded($what): "[" + $script + "] " + $what + " reloaded  @ " + field(.time);
def failed($what; $kept):
  bell + "[" + $script + "] " + paint(($what | ascii_upcase) + " RELOAD FAILED"; "31")
  + " (previous " + $kept + " kept)  " + field(.error) + "  @ " + field(.time);

(try fromjson catch null) as $entry
| if ($entry | type) != "object" then empty
  elif $entry.msg == "egress ACL reloaded" then $entry | reloaded("rules")
  elif $entry.msg == "egress ACL reload failed; keeping the previous rules"
  then $entry | failed("rules"; "rules")
  elif $entry.msg == "GitHub allowlist reloaded" then $entry | reloaded("GitHub allowlist")
  elif $entry.msg == "GitHub allowlist reload failed; keeping the previous relays"
  then $entry | failed("GitHub allowlist"; "relays")
  else empty
  end
