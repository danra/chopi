# format-deny.jq -- format one DENIED connection for display: "[script] DENY host @ time".
#
# Runs only on lines already classified as a deny (see deny-host.jq), so there is no
# classification here, only presentation: on an interactive terminal the marker is
# ANSI-red and prefixed with a BEL so a backgrounded terminal badges its Dock icon; in a
# file or a pipe it is plain.
#
# Inputs:
#   $is_interactive (bool)   colorize the DENY marker and prefix the BEL
#   $script         (string) the proxy script's name, tagging the synthesized line
#   $host           (string) the host already resolved by deny-host.jq (a name or the "?" placeholder)

def esc: ([27] | implode);   # U+001B ANSI escape, introduces the color code below
def bel: ([7]  | implode);   # U+0007 BEL, badges a backgrounded terminal's Dock icon

def paint($s; $code): if $is_interactive then esc + "[" + $code + "m" + $s + esc + "[0m" else $s end;
# A bell character (BEL) on a DENY. When this window is in the background, macOS
# Terminal.app and iTerm2 turn that bell into a red badge on the Dock icon, so a refused
# connection gets noticed even while you are looking at another window doing sandboxed work.
def bell: if $is_interactive then bel else "" end;

# Render a field: the value itself when it names something (a string with at least one
# non-whitespace character), else "?".
def field($v): if ($v | type) == "string" and ($v | test("\\S")) then $v else "?" end;

(try fromjson catch null) as $entry
| bell + "[" + $script + "] " + paint("DENY"; "31")
  + "  " + $host
  + "  @ " + field($entry.time)
