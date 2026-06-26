# format-misc.jq -- format the lines that are NOT connection requests.
#
# Runs on everything connection-request.jq rejected. Drops smokescreen's
# known noise and passes everything else through unchanged:
#   * connection-close lines (JSON with "bytes_in") -> drop
#   * "no statsd addr provided" startup warning      -> drop (smokescreen noop-statsd warning)
#   * "WARN: Error copying to "                       -> drop (client hung up mid-tunnel)
#   * anything else (startup info, other warnings)    -> pass through unchanged

(try fromjson catch null) as $entry
| if ($entry | type) == "object" and ($entry | has("bytes_in"))
  then empty
  elif contains("no statsd addr provided")
  then empty
  elif contains("WARN: Error copying to ")
  then empty
  else .
  end
