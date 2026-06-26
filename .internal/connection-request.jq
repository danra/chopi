# connection-request.jq -- does this smokescreen line record a connection request?

(try fromjson catch null) as $entry
| if ($entry | type) == "object" and ($entry | has("allow"))
  then "1"
  else empty
  end
