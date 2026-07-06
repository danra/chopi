# known-deny.jq -- is this DENY one the configured denylist already anticipates?
#
# Runs only on lines deny-host.jq has already surfaced as a DENY. smokescreen names the
# rule that decided each connection in "decision_reason"; a deny that matched the
# global_deny_list is one the user explicitly listed. Emits "1" for such a known
# deny, empty for everything else.

if (try (fromjson | .decision_reason) catch null) == "host matched rule in global deny list"
then "1"
else empty
end
