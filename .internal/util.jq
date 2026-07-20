# util.jq -- rendering helpers for jq filters

def esc: ([27] | implode);   # U+001B ANSI escape, introduces the color code below
def bel: ([7]  | implode);   # U+0007 BEL, badges a backgrounded terminal's Dock icon

def paint($s; $code): if $is_interactive then esc + "[" + $code + "m" + $s + esc + "[0m" else $s end;

# Render a field: the value itself when it names something (a string with at least one
# non-whitespace character), else "?".
def field($v): if ($v | type) == "string" and ($v | test("\\S")) then $v else "?" end;
