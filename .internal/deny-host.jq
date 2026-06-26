# deny-host.jq -- decide whether a connection line should surface as a DENY, and name its host.
#
# Runs only on lines connection-request.jq already classified as ACL decisions (a JSON object
# with an "allow" field). It is deliberately fail-safe: a spurious DENY in the log is cheap, but
# a real DENY that slips through unlogged is not. So we drop a line as a clean ALLOW *only* when
# we are certain it is one -- a single "allow" key whose value is exactly the boolean true.
# Anything else is surfaced as a DENY, named by its requested_host when that names something (a
# string with at least one non-whitespace character), or "?" otherwise:
#
#   * a denied connection ("allow": false)               -> DENY
#   * a non-boolean "allow" (string / number / null ...) -> DENY  (we trust only a real boolean)
#   * a duplicated "allow" key                           -> DENY  (ambiguous; don't guess)
#
# Duplicate keys survive only in the raw text -- fromjson keeps the last and discards the rest --
# so we count the "allow":-key occurrences in the raw line rather than in the parsed object.

# A blank or whitespace-only host collapses to "?" (via test("\\S"), true iff $host contains a
# non-whitespace char) rather than being emitted verbatim. Two reasons: a whitespace-only name
# is useless to a reader, and -- critically -- the shell consumer (classify_log) keys its
# deny/allow decision on whether this filter emitted anything, and command substitution would
# strip a newline-only line back to empty, silently dropping a real DENY.
. as $raw
| (try fromjson catch null) as $entry
| ([$raw | scan("\"allow\"[ \t]*:")] | length) as $allow_keys
| (if ($entry | type) == "object" then $entry.requested_host else null end) as $host
| if ($entry | type) == "object" and $allow_keys == 1 and $entry.allow == true
  then empty
  else (if ($host | type) == "string" and ($host | test("\\S")) then $host else "?" end)
  end
