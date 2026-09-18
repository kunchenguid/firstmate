# Client overlay: Treinar Serviços (Meta Ads)

Optional account pack for **Treinar Serviços**, product focus **CLP e IHM**.
Load only when the active diagnosis is this client.
Do not promote these constants into the general `paid-traffic-ops` body.

Parent skill: `../SKILL.md` (paid-traffic-ops).
Where this overlay is silent, follow the parent.

---

## Hard rules (account-specific bindings)

**Sale definition (parent R1).**
Venda = comprador do Produto Principal (PP), linha `TipoDeCheckout == 'ENTRY'` no checkout Assiny.
Order Bump, Upsell e Downsell são receita adicional do mesmo comprador, nunca venda nova.
Denominador de vendas = só ENTRY; receita e MC somam todas as linhas.
Contar linhas de transação como vendas inflou S/track em ~72% no histórico (318 linhas → 185 vendas PP).

**Aggregate MC/Inv (parent R2).**
Sempre MC ÷ Inv agregado; nunca média por evento.

**Funnel goal cascade (parent R3).**
Meta de MC (ex.: R$100k do funil CLP e IHM) é do funil completo (Meta + Google + IA + CI + …).
Nunca comparar um canal isolado à meta total.
Cascatear com representatividade histórica vigente do mês (ex. ilustrativo: Meta ~40%, Google ~12%, IA ~20%, CI ~28%) — confirmar pesos atuais antes de calcular.

**Contamination window (parent R4).**
Excluir **26–30 de Junho/2026** de toda análise de tendência e pacing (ataque de redirect no site).
Não reutilizar essas datas em outros clientes.

**Unit id (parent R5).**
`ad_id` é a unidade de gestão; `ad_name` é o criativo agregado.

**Approved ≠ Winner (parent R6–R7).**
Como no parent; ver gates calibrados abaixo.

**Meta cost gross-up (parent R8).**
Investimento Meta do Gerenciador / `ads_ad_metrics_gold` chega **líquido**.
Multiplicar custo Meta por **1,1383** no nível diário por `ad_id` antes de agregar.
Só o Meta leva gross-up; Google já vem com imposto embutido no BR.
ROAS Meta = faturamento ÷ investimento **bruto**; não comparar com ROAS do Gerenciador (base líquida, ~14% maior).
Break-even ROAS na base bruta = **1,12** (equivalente ~1,28 na base líquida — não usar 1,28 no relatório bruto).
Checagem: `investimento_dashboard ÷ 1,1383 ≈ investimento_líquido_Orus`.
Imposto cobrado desde janeiro/2026; série de análise desde fev/2026 usa 1,1383 em toda a série.
Se a alíquota mudar, declarar o fator por período.

**MC formula (parent R9).**

```
MC = paid_net_value − investimento_bruto
%MC = MC ÷ paid_value
ROAS = paid_value ÷ investimento_bruto
```

Campo `taxes` já está dentro de `paid_net_value` — não subtrair de novo (teste Ago/2026: ~R$3.246 / ~2% MC escondidos).

**Refunds (parent R10).**
Incluir status `paid`, `completed`, `dispute`, `refunded` em faturamento e compradores PP.
`refunded_value` é métrica à parte.
Fora: `expired`, `refused`, `waiting_payment`, `status_not_mapped`.
Excluir `refunded` quebrou fechamento Ago/2026 (510 vs 520 compradores; R$276.879 vs R$287.220).

**Hotmart in macro (parent R11).**
`source_name` ∈ {`assiny`, `hotmart`}; ambos contam.
Hotmart cai no canal `other`.
Pandas ≥3: colunas texto não são `object` — não filtrar dtype==object.

---

## Calibrated gates (Fev–Jul/2026 extended base)

| Gate | Value |
|---|---|
| Validation window | 5 days OR R$300 spend, whichever first |
| Approve (A) | ≥2 sales AND MC% ≥50% AND ROAS ≥2.5 in window |
| Early kill (C) | 0 sales after R$150, OR MC < −R$100 with ROAS < 0.8 |
| Winner | ≥5 sales AND MC% ≥30% lifetime on ad_id |
| Scale-ready | ≥7 days life; R$500–1.000 accumulated; Criterion A on last 3 consecutive days |
| Post-scale window | 5–7 days; days 1–2 noise |
| Noise filter | ignore ads with only 1 sale when ranking |
| Matrix eligibility | inv ≥ R$200 |

Notes:

- Approve recall ~55%; 5 historical winners missed A (emblematic: **AD14_H01** — 1 early sale → 14 sales, 70% MC%).
- Kill precision: 100% on 82 flagged ads Fev–Jul; zero winners blocked. Problem was ~52% adherence in June (~R$13.363 avoidable loss), not the threshold.
- Do not raise the R$150 kill ceiling to R$300 (becomes floor; ~R$7.600 extra loss in estimate).
- No automated revoke rule for already-approved ads; lengthen curve to 14d+, reduce before pause.

---

## Confirmed anti-patterns (this account only)

- **Advantage+ Audience** (with or without Bid Cap): 53 ad_ids, 0 winners; MC ≈ −R$8.980. Do not scale winners by duplicating into Adv+_Bid; raise budget on the live set.
- **Fluxo 2 (VAR reedits):** 50 tested, 0 winners; Hold Rate ~12% F1 → ~7% F2.
- **Hyper-narrow interest / lookalike manual:** 0 winners, negative MC.

## Structure and scale (corrected vs older v7 short-base reads)

- No universal "isolated > batch". On aggregate MC/Inv, batch median beat isolated (0.43 vs −0.09) in the extended base; 13/36 paired videos preferred isolated. Case-by-case.
- **Frio Lote** = volume/discovery engine; recent MC/Inv collapsed 29% → 5% (live bottleneck).
- **Frio Isolado** efficient for already-validated creatives (~43% MC/Inv post-approve) only with strict Criterion C.
- First scale (ad_id #2) out-earned origin in extended base (~R$21k vs ~R$12,5k MC); decay from #3 onward.
- Weekly seasonality: only **Friday weak** survived extended base; do not operationalize other DOW rules from v7.
- Budget × prior ROAS: worst behavior = hold spend on sustained ROAS <1 (MC/Inv ≈ −11%, ≈ −19% on material spend). Moderate +15–40% on ROAS 2–3.5 ≈ +58%. 1-day window is noise.
- Open hypothesis (inconclusive): pausing one ad inside a healthy group degrades the group over time — insufficient sample.

## Creative alerts (not fixed pillars)

- Do not ship a fixed pillar list; recompute winners monthly from the Winner gate.
- **AD14_H01** (RMKT, ~70% MC%): underscaled gem, single ad_id RMKT-only; cold port risk. Start ~R$100–150/day, validate 3–5d, +20% every 2d if holds.
- **AD29_H01**: historical batch pillar; recent fatigue — do not treat as eternally stable.

---

## Data contract

### Ads export (Meta) — daily grain, 26 columns

Key fields: `date`, `campaign_id`, `Nome da Campanha`, `ad_group_id`, `ad_group_name`, `ad_id`, `ad_name`, `R$ Investimento`, `R$ CPA`, `R$ TMF`, `R$ Faturamento`, `ROAS`, `R$ Margem de Contribuição`, `%Margem` (text — parse), impressions/CPM/hook/hold/clicks/CTR/CPC, page views, connect rate, initiate checkout, page conv, `Vendas` (should be ENTRY-pure — validate).

S/track row may arrive with `date = 00:00:00` as `datetime.time` — filter before date ops.

### Checkout export (Assiny) — transaction grain

Fields: created date, product/offer names, `TipoDeCheckout` (ENTRY / ORDERBUMP / UPSELL / DOWNSELL), `Status`, channel (filter `META`), `UtmContent` (numeric ad_id when tracked), `Valor`/`ValorLiquido` (**cents — ÷100**), `TransactionId`, identity.

**S/track** = Meta-attributed sales without numeric ad_id, in dashboard sense, always the sum of:

1. channel `META` with non-numeric / null / `direct` / `{{ad.id}}` utm_content
2. channel `other` rows the dashboard also counts as S/track

Omitting (2) undercounted Ago/2026 (19 vs 24). Attribute to Meta Ads (same exclusive offer page); distribute by real event date.
S/track MC% is high (no attributed spend); decline with tracking maturity is not channel decay.

### Scope

- Period: available base (e.g. Fev/2026) through last **complete** day; exclude contamination window; exclude in-progress day from primary analysis.
- Campaign filter: substring **`CLP e IHM`** in campaign name — never a fixed name list.
- List captured campaigns and spend in the report before ratios.
- Reconcile with R8 dashboard check.
- Exclude DCS and IF from main Meta pacing unless asked (separate products; verbose pipe naming).

### Orus connector (project Treinar Servico)

| Need | Source |
|---|---|
| Media per ad_id/day | `ads_ad_metrics_gold.cost` (net → ×1.1383) |
| PP sales | `assiny_transactions_gold.transactions_pp` — not `transactions` |
| Revenue / MC | `paid_value` gross; MC = `paid_net_value` − gross media |
| Refunds | `refunded_value`; keep in sales counts per R10 |
| Platform | `source_name` assiny\|hotmart |
| Attribution | `utm_content` ↔ `ad_id` |
| Funnel prefix in `offer_name` | `CLPF01` CLP e IHM; `IFF01` IF; `SIF01` DCS |
| Channel | `channel` META, IA, CI, Google, other |

### Dashboard reconciliation order

1. Scope — "Visão Geral" is whole operation, not only CLP e IHM.
2. Cost base — dashboard gross vs Orus/Meta net.
3. MC formula — double tax subtract.
4. Status / refunds.
5. Period / in-progress day.

**Known unresolved:** channel buyer counts (Ago/2026 IA/CI cards) disagree while revenue/MC match; dashboard channel cards summed 457 vs total 520. Report as gap; never force-fit counts. Does not block pause/scale (cascade uses MC share).

---

## Naming conventions

Two conventions: concise CLP/IHM vs verbose pipe-separated DCS/IF — never merge.

- Campaign: `PRODUTO_TIPO_[MOD]_DATA` — `TC` creative test, `TP` audience test, `Rmkt`, `Bid` = Bid Cap, date `DDMM`.
- Ad set: `Adv+_Bid_[ad]` anti-pattern; bare ad name = isolated ABO 1-1; `ADs_[MêsDia]_v[N]` = batch wave (**vN is wave, not Fluxo 2**); `RMKT+…`.
- Ad: F1 `AD##_H##_V00_[produto]_FB`; F2 reedits `VAR#_AD##_H##_…`.
- Critical: `VAR` in ad_name = Fluxo 2; `v2`/`v3` in ad set name = sequential wave.

---

## Funnel vocabulary (local)

- PP, OB, Up, Downsell as in parent sale definition.
- CPA = Inv ÷ PP sales; TMF = Revenue ÷ PP sales (mix shift without PP change ⇒ OB/Up mix).
- Metric funnel order: CPM → Hook → Hold → CTR → CPC → PV → Connect → IC → Page conv → Sales → CPA → TMF.
- ABO vs CBO; bid strategies and audience types as platform defaults — prefer this account's history over generic platform lore.
- Meta is ~85% of acquisition spend; other channels lower CPA, lower ceiling; Google hard to scale.
- Monetization thesis: TMF target ≈ 2× CPA implies post-PP revenue.

---

## Report expectations

Follow parent section 12 structure.
Language impersonal.
Action plan must separate Criterion C / A / wait-window mandates from ROAS×motion suggestions.
Always print numeric `ad_id` columns.
