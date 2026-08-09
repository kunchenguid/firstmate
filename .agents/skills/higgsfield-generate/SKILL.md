---
name: higgsfield-generate
description: Safely generate a single image or video with the Higgsfield CLI through explicit upload and credit approvals. Use when the captain asks to create or animate visual media with Higgsfield, including prompt-only work and approved local image or video references.
user-invocable: false
metadata:
  internal: true
---

# Safe Higgsfield generation

Use `scripts/safe_generate.py` for every paid generation.
Never call `higgsfield generate create` directly.

## Boundaries

- Support one image or video generation per approved run.
- Do not install or update software, execute remote installers, reveal authentication tokens, or open a login flow.
- Do not create websites, deploy, publish, import marketing data, train identities, create Soul IDs, or generate audio or 3D assets.
- Do not fetch a remote reference URL.
- Do not run variants, batches, retries, or edits under an earlier approval.
- Stop and ask the captain when the CLI is missing, authentication is unavailable, or the requested work is outside these boundaries.

## Prepare the request

Create a temporary directory with `mktemp -d` and write `request.json` there with the environment's safe file-editing mechanism.
Never interpolate prompt text or user-controlled parameters into a shell command.

Use this schema:

```json
{
  "job_type": "nano_banana_2",
  "prompt": "Describe the requested image or video.",
  "parameters": {
    "aspect_ratio": "1:1"
  },
  "media": [
    {
      "flag": "image",
      "value": "/absolute/path/to/reference.png"
    }
  ]
}
```

Use an empty `media` array for prompt-only work.
Use only model parameters shown by `higgsfield model get <job_type> --json`.
The wrapper accepts only absolute regular-file paths or existing Higgsfield UUIDs for media.

## Approval sequence

1. Run `python3 scripts/safe_generate.py plan /absolute/temporary/directory/request.json`.
2. If the plan lists uploads, show the captain every exact path and obtain explicit approval for those files.
3. Only after upload approval, run `python3 scripts/safe_generate.py upload /absolute/temporary/directory/request.json --approval-token <token-from-plan> --output /absolute/temporary/directory/uploaded-request.json`.
4. Use the uploaded request from then on.
5. Run `python3 scripts/safe_generate.py cost /absolute/temporary/directory/uploaded-request.json --receipt /absolute/temporary/directory/cost-receipt.json`.
6. Show the captain the exact model, job count, parameters, uploaded references, displayed vendor `credits` value, and the wrapper's emitted approval-scope warnings.
7. Obtain explicit approval only for the request and displayed vendor `credits` value shown.
8. Only after cost approval, run `python3 scripts/safe_generate.py run /absolute/temporary/directory/uploaded-request.json --cost-receipt /absolute/temporary/directory/cost-receipt.json`.

For prompt-only work without step 3, use `/absolute/temporary/directory/request.json` in steps 5 and 8.
Do not combine upload approval with cost approval unless the captain explicitly approves both after seeing both disclosures.
Treat every retry, variation, edit, or additional output as a new generation that must repeat the cost and approval steps.
For a multi-job request, stop and obtain separate bulk approval for an enumerated job count and total estimated credits, then execute each job through its own cost receipt.

## Report the result

Return the completed output URL or file, the model, and the approved vendor `credits` value reported by the wrapper.
Distinguish a completed job from visual quality inspection.
If the job fails or times out, report the failure and do not retry automatically.
