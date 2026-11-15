# util.jq -- rendering helpers for jq filters

# Render a field: the value itself when it names something (a string with at least one
# non-whitespace character), else "?".
def field($v): if ($v | type) == "string" and ($v | test("\\S")) then $v else "?" end;
