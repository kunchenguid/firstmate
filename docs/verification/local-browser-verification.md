# Local browser verification policy

Audience: maintainer verification.

This record verifies the Firstmate contract that PR-based workers complete local browser or server-only verification before publication.
It does not claim that any project's application, credentials, or production authentication were tested here.

## Maintainer verification on 2026-10-01

The shell owners parsed successfully with no output and exit status 0:

```sh
bash -n bin/fm-dod-lib.sh
bash -n bin/fm-brief.sh
bash -n tests/fm-brief.test.sh
```

The focused brief regression passed with exit status 0:

```sh
bash tests/fm-brief.test.sh
```

Relevant output was:

```text
ok - fm-brief.sh: PR-based delivery requires local verification before publication
ok - fm-brief.sh: PR-based done requires a non-draft PR; a deliberate draft declares a wait
```

The documentation inventory check passed with exit status 0:

```sh
bash bin/fm-doc-audience-check.sh
```

Observed output:

```text
fm-doc-audience-check: ok surfaces=119 local_links=707
```

The focused regression exercises the generated direct-PR and no-mistakes delivery contracts and confirms that local-only delivery does not receive the PR publication requirement.
