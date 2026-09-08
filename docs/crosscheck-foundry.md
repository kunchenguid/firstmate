# Azure-billed regular GLM

Crosscheck supports regular `FW-GLM-5.2` through Fireworks on Microsoft Foundry with pay-per-token `DataZoneStandard` billing.
The deployment must be named `crosscheck-glm-5p2`; this selector maps to Pi provider `foundry-glm` and retains the existing two-stage review.
Provisioned capacity and the Fast model are not required.

The coordinator owns `FM_HOME/config/crosscheck-foundry.json`, containing only `endpoint`, an HTTPS Foundry resource URL ending in `.services.ai.azure.com/openai/v1`.
This file registers the exact allowed endpoint; credentials cannot redirect it.
Keep the resource hostname and API key in private operational configuration, not in tracked files.
The dedicated Pi account's `models.json` uses that endpoint, `api: openai-completions`, its resource API key, and model ID `crosscheck-glm-5p2`.
Match the registered compatibility settings and model rates in `bin/fm_crosscheck_foundry.py`.
The guest accepts only the coordinator-selected host and the fixed Chat Completions path under the existing network isolation.

Stage a candidate reviewer roster through `FM_CROSSCHECK_REVIEWER_CONFIG` and run the supported `bin/fm-crosscheck.sh run` wrapper against a fixed PR head before changing the serving roster.
Replace only the first reviewer entry with Pi, model `crosscheck-glm-5p2`, effort `xhigh`, and the dedicated account directory; retain the existing Codex fallback entries.
New processes read the new roster while in-flight reviews retain their selected identity.
Rollback restores the previous first reviewer entry and credential home; retain the Foundry endpoint configuration so its historical ledgers remain readable.

Azure retail rates for regular GLM 5.2 Data Zone Standard verified on 2026-09-08 are USD 1.54 per million input tokens, 0.15 per million cached input tokens, and 4.84 per million output tokens.
Telemetry identifies these estimates as `azure-retail-foundry-regular-rates`; they are not invoice measurements.
The TPM setting limits throughput, not daily spending, and does not reserve provisioned capacity.
Subscription acceptance does not itself prove promotional-credit eligibility.

Sources: [Microsoft setup](https://learn.microsoft.com/en-us/azure/foundry/how-to/fireworks/enable-fireworks-models) and [Azure Retail Prices API](https://prices.azure.com/api/retail/prices).
