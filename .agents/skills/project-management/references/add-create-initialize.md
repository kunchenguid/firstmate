# Add, create, and initialize a project

Confirm the source URL, local project name, delivery posture, and autonomy posture, stating the resolved default for each rather than asking the captain to invent one.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
A `no-mistakes` or `no-mistakes-prod-only` project must have an `origin` remote and must complete the initialization procedure below, because a conditional policy's product-facing work runs the pipeline while its internal-only work still takes the direct PR.
A `direct-PR` project needs an `origin` remote but skips no-mistakes initialization.
A `local-only` project may have no remote and skips no-mistakes initialization.
Confirm the matching CLI is authenticated for a non-GitHub host: `glab auth login` for a GitLab project, whose merge watch and merge use glab, or a `tea login add` for a `forge=forgejo` project, whose merge watch, merge, and generated ship brief use tea.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery posture, defaulting visibility to private and the posture to `no-mistakes-prod-only`, then obtain the captain's explicit consent for those exact values; a stated default never replaces that consent.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, add the registry entry, and initialize it according to its delivery posture.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
A new repository has no commit, and spawn refuses to dispatch work into a project with an unborn `HEAD`.
Tell the captain that the project needs a first commit.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Initialize

Run no-mistakes initialization only for `no-mistakes` and `no-mistakes-prod-only` projects:

```sh
(cd projects/<name> && no-mistakes init && no-mistakes doctor)
```

Initialization configures the local gate and does not vendor a no-mistakes skill into the project.
Do not create a commit merely because initialization ran.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.
