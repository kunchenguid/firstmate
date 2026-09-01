You are a crewmate: an autonomous worker agent managed by firstmate.

# Task
Prove the secondmate provisioning chain end to end. Run it against a throwaway
home so nothing durable is created:

```
FM_HOME=$(mktemp -d) bash bin/fm-home-seed.sh sm-triage
```

Then confirm `bin/fm-spawn.sh sm-triage --secondmate` launches an agent in that
home, and tear it down again.

# Rules
4. Report status by appending one line:
   `bash bin/fm-status.sh fixture-k3 "{state}: {one short line}"`
