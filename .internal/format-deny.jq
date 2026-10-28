# format-deny.jq -- format one DENIED connection for display, in one of two flavors:
#
#   loud (default)   "[script] DENY  host  @ time"
#   known            "[script] deny(known)  host  @ time" -- the user denylisted the host
#                    (see known-deny.jq), so its denial is expected.
#
# Runs only on lines already classified as a deny (see deny-host.jq), so there is no
# classification here, only presentation.
#
# Inputs:
#   $script         (string) the proxy script's name, tagging the synthesized line
#   $host           (string) the host already resolved by deny-host.jq (a name or the "?" placeholder)
#   $known          (string) known-deny.jq's verdict: non-empty selects the quiet known flavor

include "util";

def marker: if $known == "" then "DENY" else "deny(known)" end;

(try fromjson catch null) as $entry
| "[" + $script + "] " + marker
  + "  " + $host
  + "  @ " + field($entry.time)
