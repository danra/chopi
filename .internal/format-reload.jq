# format-reload.jq -- recognize and render the proxy's hot-reload lines of the network config,
# which holds the rules and the GitHub allowlist the relays serve.
#
# Emits the display line when the input is a reload line, else empty -- the caller
# falls through to format-misc.jq on empty. Two flavors:
#
#   reloaded   "[script] network config reloaded  @ time" -- routine, just visible enough
#              to confirm an edit took effect.
#   failed     "[script] NETWORK CONFIG RELOAD FAILED (previous config kept)  <error>  @ time"
#              -- loud like a DENY: the user's edit did NOT take effect, and the proxy
#              keeps enforcing the previous config.
#
# Each line names what reloaded by the entry's "what", e.g. "workspace network config reloaded"
# for a workspace's own network config.
#
# .internal/proxy/main.go emits the msg strings matched here (its networkReloaded and
# networkReloadFailed constants). classify_log (.internal/classify-log.sh) also matches them, on
# the raw line, to fire its reload hook. Keep all three in sync.
#
# Inputs:
#   $script         (string) the proxy script's name, tagging the synthesized line

include "util";

# Render the reload entry given as input, as a reload or as a failed reload, which keeps the
# previous config.
def what: .what // "network config";
def reloaded: "[" + $script + "] " + what + " reloaded  @ " + field(.time);
def failed:
  "[" + $script + "] " + (what | ascii_upcase) + " RELOAD FAILED"
  + " (previous config kept)  " + field(.error) + "  @ " + field(.time);

(try fromjson catch null) as $entry
| if ($entry | type) != "object" then empty
  elif $entry.msg == "network config reloaded" then $entry | reloaded
  elif $entry.msg == "network config reload failed; keeping the previous config"
  then $entry | failed
  else empty
  end
