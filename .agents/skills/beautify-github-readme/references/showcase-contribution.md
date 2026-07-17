# Optional showcase contribution

Use this workflow only after the user explicitly approves the finished README and opts into sharing a public repository with the `beautify-github-readme` showcase.

## Eligibility gate

Confirm all of the following before preparing upstream changes:

- The repository is public.
- The user owns, maintains, or is authorized to represent it.
- The finished README is already published and visible at the repository URL.
- The upstream showcase does not already list the repository.

Do not treat an attribution badge as a requirement. A repository may be proposed with or without the badge.

## Ask once, without pressure

Use neutral wording and make declining easy:

> If you'd like to share this result, I can draft a small PR to add the public repository to the real-world showcase in `oil-oil/beautify-github-readme`. This is completely optional, and the upstream maintainers will decide whether to merge it.

Do not repeat the offer after a decline. Do not create an issue, discussion, fork, branch, or PR merely because the user expressed satisfaction.

## Prepare the proposal

1. Inspect the latest default branch of `https://github.com/oil-oil/beautify-github-readme`.
2. Locate the current showcase list and check for duplicates.
3. Draft one factual sentence explaining what the finished README demonstrates. Do not invent adoption, testimonials, results, or product capabilities.
4. Keep the English and Simplified Chinese showcase lists aligned. Show both proposed entries to the user for approval.
5. Check whether a showcase SVG or its accessible description explicitly enumerates repositories. Update it only when needed to keep the visual and alt text accurate; do not overcrowd the graphic merely to add another logo or label.
6. Show the exact upstream files and diff that would change.

Typical upstream files are `README.md`, `README.zh-CN.md`, and—only when its content becomes inaccurate—the relevant showcase SVG.

## Publish only with explicit approval

After the user approves the exact listing copy and diff, ask for explicit authorization to open the PR. Then:

- Use a normal branch and PR when the authenticated account has upstream access.
- Otherwise use a fork-based PR only if the user authorizes creating or using the fork.
- If neither route is available, provide the prepared patch and PR text without creating external state.
- Report the PR URL and state clearly that upstream maintainers may edit, decline, or merge it.

Never push directly to the upstream default branch. Never imply that a showcase submission is already accepted.
