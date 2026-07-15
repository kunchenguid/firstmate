# PR screenshots for UI work

Firstmate's standard for UI ship work is that the PR demonstrates the change with screenshots, so a reviewer sees the result without checking out the branch.
`bin/fm-pr-screenshots.sh` is the helper that makes this possible; its header comment and `--help` are the authoritative mechanics.
The `pr-screenshots` agent-only skill owns when firstmate applies this and the exact dispatch and embed steps.
This doc is the mechanism narrative and the empirical record behind the mechanism choice.

## The mechanism: GitHub release assets

The hard part is getting a durable image URL that GitHub markdown renders inline via `![](url)`.
`gh-axi` has no attachment/upload verb, and GitHub's web drag-and-drop upload (`github.com/user-attachments/assets/...`) needs a browser session cookie plus CSRF token, not a `repo`-scoped token, so a CLI cannot drive it.

The helper uploads each screenshot as a GitHub **release asset** on a dedicated `fm-pr-assets` prerelease in the target repo, and references the stable URL `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`.
Release assets live in GitHub's release storage, not the git object store, so they add zero bloat to code branches or `main` history, need no new repo or external host, and upload with the ordinary `repo` token scope.
The URL is fully deterministic from `(owner, repo, tag, asset-name)`, which is why `--dry-run` prints byte-identical markdown to a live run without uploading.

Assets in the single shared `fm-pr-assets` release are namespaced by a per-task prefix (the sanitized `fm/<id>` branch by default) so parallel tasks never collide; `gh release upload --clobber` makes a re-run overwrite its own assets.
The release is a prerelease so it never claims the repo's "Latest release" slot.
The assets must persist for as long as the PR references them, exactly like any other image-hosting choice.

## Where screenshots live and how each path embeds them

A crewmate doing UI work captures the key states of its change with the project's own browser tooling (Playwright or chrome-devtools-axi) and leaves the images under `data/<id>/screenshots/` in the firstmate home, never committed into the product repo's branch.
The upload and any PR-body edit are project writes, so the crewmate (never firstmate) runs the upload, while firstmate only ever runs `embed`, a PR-body edit that is part of its normal PR handling.
That split drives the two delivery paths, whose exact dispatch and embed steps the `pr-screenshots` skill owns:

- direct-PR: the crewmate folds the helper's markdown into its own `gh-axi pr create --body-file`.
- no-mistakes: the crewmate saves the markdown to `data/<id>/screenshots.md`, and firstmate embeds that block into the PR body after the pipeline opens it.

The emitted block carries a `<!-- fm-pr-screenshots -->` marker so `embed` is idempotent and never double-appends.

## Empirical verification

Verified 2026-07-07 with gh 2.81.0, gh-axi 0.1.24, Google Chrome 148.0.7778.215, shellcheck 0.10.0, against a throwaway public repo `MabezDev/fm-screenshot-render-probe`.

### A release-asset URL serves the bytes, but with surprising headers

`curl -sIL https://github.com/<owner>/<repo>/releases/download/v-probe/probe.png`:

```
HTTP/2 302
location: https://release-assets.githubusercontent.com/.../...?...  (short-lived, signed)
HTTP/2 200
content-type: application/octet-stream
content-disposition: attachment; filename=probe.png
content-length: 139
```

The stable `github.com/.../releases/download/...` URL 302-redirects to a short-lived signed URL that serves the bytes as `application/octet-stream` with an `attachment` disposition, not `image/png`.
The stable top URL itself does not expire; it re-issues a fresh signed redirect on each request.

### GitHub renders the URL as a direct inline image

`![screenshot](<release-download-url>)` in an issue body, read back via `Accept: application/vnd.github.full+json`, produced `body_html`:

```html
<p dir="auto"><a target="_blank" rel="noopener noreferrer" href="https://github.com/.../releases/download/v-probe/probe.png"><img src="https://github.com/.../releases/download/v-probe/probe.png" alt="screenshot" style="max-width: 100%;"></a></p>
```

The same markdown in a real pull request body renders identically (issues and PRs share the same GitHub-flavored-markdown renderer):

```html
<p dir="auto"><a ... href=".../releases/download/fm-pr-assets/fm-helper-e2e-login.png"><img src=".../releases/download/fm-pr-assets/fm-helper-e2e-login.png" alt="login" style="max-width: 100%;"></a></p>
```

The URL becomes a direct `<img src>` (not camo-proxied, not stripped to a plain link), because it is a github.com URL that GitHub trusts.

### A browser decodes the octet-stream bytes and paints the image

The `application/octet-stream` content-type and `attachment` disposition do not stop an `<img>` element from decoding the bytes.
Rendering `<img src="<release-download-url>" width="120" height="40">` on a white page in headless `google-chrome-stable --headless=new --screenshot` and analyzing the pixels showed the full 120x40 image region painted with the image's color (4800 of 4800 pixels), zero broken/white pixels.
Screenshotting the actual public issue page confirmed the image is visible inline to an anonymous viewer.

### Private repos need a logged-in reviewer session

The `releases/download/<tag>/<file>` URL that the inline `<img>` points at authorizes off the viewer's github.com browser session, not a token.
On a private repo it returns 404 to both unauthenticated and token-authenticated (PAT) requests, so command-line or CI tooling cannot fetch the image; the asset itself is still retrievable with auth through the release-assets API.
A human reviewer viewing the PR while logged in does load it: the image renders inline, captain-verified in-browser on a private repo on 2026-07-08.
So the standard works for human reviewers on private (the firstmate default) and public repos alike; only unauthenticated or token-only tooling cannot fetch the rendered image.

### Conclusion

Release-asset URLs render inline in PR and issue bodies reliably for a logged-in reviewer (captain-verified on both public and private repos), with no git bloat, no new repo, and token-only upload auth.
This is why the helper uses release assets rather than an orphan assets branch (git object-store bloat), the web user-attachments upload (browser-session auth, fragile), or a separate assets repo (new hosting).
