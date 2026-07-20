# format-deny.jq -- format one DENIED connection for display, in one of two flavors:
#
#   loud (default)   "[script] DENY  host  @ time" -- on an interactive terminal the
#                    marker is ANSI-red and prefixed with a BEL so a backgrounded
#                    terminal badges its Dock icon; in a file or a pipe it is plain.
#   known            "[script] deny(known)  host  @ time" -- always plain: the user
#                    denylisted the host (see known-deny.jq), so its denial is expected.
#
# Runs only on lines already classified as a deny (see deny-host.jq), so there is no
# classification here, only presentation.
#
# Inputs:
#   $is_interactive (bool)   colorize the loud DENY marker and prefix the BEL
#   $script         (string) the proxy script's name, tagging the synthesized line
#   $host           (string) the host already resolved by deny-host.jq (a name or the "?" placeholder)
#   $known          (string) known-deny.jq's verdict: non-empty selects the quiet known flavor

include "util";

# A bell character (BEL) on a loud DENY. When this window is in the background, macOS
# Terminal.app and iTerm2 turn that bell into a red badge on the Dock icon, so a refused
# connection gets noticed even while you are looking at another window doing sandboxed work.
def bell: if $is_interactive and $known == "" then bel else "" end;

def marker: if $known == "" then paint("DENY"; "31") else "deny(known)" end;

(try fromjson catch null) as $entry
| bell + "[" + $script + "] " + marker
  + "  " + $host
  + "  @ " + field($entry.time)
