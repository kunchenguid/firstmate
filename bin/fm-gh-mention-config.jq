# Validate and flatten config/gh-mentions.json for bin/fm-gh-mention.sh.
#
# Prints, on success:
#   <enabled>
#   \n--trusted\n<one compact grant object per line>
#   \n--markers\n<marker>...\n--repos\n<owner/name>...
# and otherwise the single line "invalid: <reason>". There is deliberately no
# repair path: a typo in trusted_logins would silently widen or narrow who
# firstmate obeys, so an unreadable field stops the plane instead.
#
# A trusted entry is either a plain login string, which is a permanent
# authorization, or an object carrying that login plus optional bounds. Both
# normalize to {login, until, remaining} so the caller has one shape to read.

def login_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$");
def repo_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$");
# A marker is compared as a literal substring, so whitespace or a leading dash
# would either never match a real comment or collide with this format's own
# section separators.
def marker_ok: type == "string" and (length > 0) and (test("[[:space:]]") | not) and (startswith("-") | not);
def until_ok: type == "string" and ((try (fromdateiso8601 | true) catch false));
def remaining_ok: type == "number" and (. == floor) and . >= 0;

def grant_keys: ["login", "until", "remaining"];
def grant_problem:
  if type == "string" then (if login_ok then null else "has a \"trusted_logins\" entry that is not a GitHub login" end)
  elif type == "object" then
    if ((keys - grant_keys) | length) > 0
      then "has a \"trusted_logins\" entry with unknown key(s): " + ((keys - grant_keys) | join(", "))
    elif (.login | login_ok | not) then "has a \"trusted_logins\" entry whose \"login\" is not a GitHub login"
    elif (.until != null) and (.until | until_ok | not)
      then "has a \"trusted_logins\" entry whose \"until\" is not an ISO 8601 timestamp"
    elif (.remaining != null) and (.remaining | remaining_ok | not)
      then "has a \"trusted_logins\" entry whose \"remaining\" is not a whole number of requests"
    else null end
  else "has a \"trusted_logins\" entry that is neither a login nor a grant object"
  end;

def normalize_grant:
  if type == "string" then {login: ., until: null, remaining: null}
  else {login: .login, until: (.until // null), remaining: (.remaining // null)}
  end;

def known: ["enabled", "trusted_logins", "markers", "repos"];

def problem:
  if type != "object" then "must be a JSON object"
  elif ((keys - known) | length) > 0 then "has unknown key(s): " + ((keys - known) | join(", "))
  elif (.enabled | type) != "boolean" then "needs a boolean \"enabled\""
  elif (.trusted_logins | type) != "array" then "needs an array \"trusted_logins\""
  elif (.trusted_logins | length) == 0 then "needs at least one login in \"trusted_logins\""
  elif any(.trusted_logins[]; grant_problem != null)
    then ([.trusted_logins[] | grant_problem | select(. != null)] | first)
  elif ((.trusted_logins | map(normalize_grant.login | ascii_downcase) | unique | length)
        != (.trusted_logins | length))
    then "lists the same login in \"trusted_logins\" more than once"
  elif (.markers != null) and ((.markers | type) != "array" or (.markers | length) == 0)
    then "needs \"markers\" to be a non-empty array when present"
  elif (.markers != null) and any(.markers[]; marker_ok | not)
    then "has a \"markers\" entry that is empty, contains whitespace, or starts with a dash"
  elif (.repos != null) and ((.repos | type) != "array")
    then "needs \"repos\" to be an array when present"
  elif (.repos != null) and any(.repos[]; repo_ok | not)
    then "has a \"repos\" entry that is not owner/name"
  else null
  end;

if problem then "invalid: " + problem
else
  [(.enabled | tostring), "--trusted"]
  + (.trusted_logins | map(normalize_grant | tojson))
  + ["--markers"] + ((.markers // ["@firstmate", "@captain"]) | map(.))
  + ["--repos"] + ((.repos // []) | map(.))
  | join("\n")
end
