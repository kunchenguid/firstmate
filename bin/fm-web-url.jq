def valid_ipv4:
  (split(".") | length) == 4
  and (split(".") | all(.[];
    test("^[0-9]{1,3}$") and (tonumber >= 0 and tonumber <= 255)));

def valid_web_host:
  . as $original |
  (if ($original | endswith(".")) then $original[:-1] else $original end) as $host |
  ($host | length) > 0
  and (if ($original | endswith(".")) then ($original | length) <= 254 else ($original | length) <= 253 end)
  and ($host | split(".") | all(.[];
    (length > 0 and length <= 63 and test("^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"))))
  and (if ($host | test("^[0-9.]+$"))
       then ($host | valid_ipv4)
       else true end);

def normalized_ipv6:
  if contains(".") then
    ([try capture("^(?<prefix>.*:)(?<ipv4>[^:]+)$") catch null] | .[0] // null) as $mixed |
    if $mixed != null and ($mixed.ipv4 | valid_ipv4)
    then $mixed.prefix + "0:0"
    else null
    end
  else .
  end;

def valid_ipv6:
  normalized_ipv6 as $address |
  if $address == null or ($address | test("^[0-9A-Fa-f:]+$") | not) then false
  else ($address | split("::")) as $pieces |
    ($pieces | map(if length == 0 then [] else split(":") end)) as $groups |
    ($groups | all(.[]; all(.[]; test("^[0-9A-Fa-f]{1,4}$"))))
    and (if ($pieces | length) == 1
         then ($groups[0] | length) == 8
         else ($pieces | length) == 2 and (($groups[0] | length) + ($groups[1] | length)) < 8
         end)
  end;

def valid_web_url:
  if type != "string" or test("[[:cntrl:][:space:]\\\"<>\\\\]") then false
  else . as $candidate |
    ([try capture("^(?<scheme>https?)://(?<authority>[^/?#]+)(?<tail>[/?#].*)?$"; "i") catch null] | .[0] // null) as $url |
    if $url == null or ($url.authority | contains("@")) then false
    else ([try ($url.authority | capture("^(?:\\[(?<ipv6>[^]]+)\\]|(?<host>[^:]+))(?::(?<port>[0-9]+))?$")) catch null] | .[0] // null) as $authority |
      if $authority == null
        or (if ($authority.ipv6 // "") != ""
            then (($authority.ipv6 | valid_ipv6) | not)
            else (($authority.host | valid_web_host) | not)
            end)
      then false
      elif ($authority.port // "") != "" and (($authority.port | length) > 5 or ($authority.port | tonumber) > 65535) then false
      else (($candidate | gsub("%[0-9A-Fa-f]{2}"; "") | contains("%")) | not) end
    end
  end;

def web_url_or_empty:
  . as $candidate |
  if valid_web_url then $candidate else "" end;

def https_url_or_empty:
  . as $candidate |
  ($candidate | web_url_or_empty) as $url |
  if ($url | ascii_downcase | startswith("https://")) then $url else "" end;
