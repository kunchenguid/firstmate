---
name: loopd
description: 把当前任务变成一个「每轮 = 一个 dynamic workflow」的自驱 loop,并自动起草 loop 方案。当 founder 说「开个 loop / 跑个 loop / loopd / 用 loop 做这件事 / 这个长任务循环跑 / 自驱循环 / 让它自己迭代几轮 / overnight 跑 / 跑满 N 小时」时使用。调用后我先读当前 context,出一份草案(目标判据 + 建议总时长 + 每轮 dynamic workflow 的 layer 设计:每层干什么/派几个 agent/什么模型),问你确认总时长(你唯一必填项)+ 让你微调分层,确认后就开跑。每完成一轮 dynamic workflow = 一次心跳(同步进度 + 判停),跑到「达标 / 连续没新增 / 时间预算耗尽」最先满足才停。这是 founder 自己设计的 loop 骨架的产品化,质量来自「每轮都是一个完整 dynamic workflow」。
---

# loopd —— 每轮一个 dynamic workflow 的自驱 loop

把一个长任务交给一个**有骨架、会自己写好方案、跑满你给的时间预算**的 loop。
你只定**总时长**和**每轮的 layer / 人数 / 模型分配**;骨架、判停、对抗复审、防卡死、进度同步,全由这个 skill 写好。

**为什么每轮是一个 dynamic workflow**:founder 实测,把一轮的活儿拆成一个完整的多 layer fan-out workflow(广搜 → 对比/核验 → 综合,层层对抗复审),单轮质量远高于「主循环里一个 agent 顺着干」。所以本 skill 的心跳单位 = **一个 dynamic workflow 跑完**,不是一次 agent 调用。

---

## 铁律(写死,任何一轮都不许破)

1. **每轮 = 一个 dynamic workflow**(`Workflow` 工具),不是单个 agent。心跳 = 一轮 workflow 跑完。
2. **总时长是「预算/护栏」,不是「工期承诺」**。我绝不对外说「这任务 X 小时能做完」——X 小时是 founder 给 loop 的运行预算(类似 cron heartbeat),到点就收尾,不是对完成度的承诺。这与「绝不给时间估算」不冲突:估的是预算上限,不是交付时间。
3. **完成判据必须机器可验证**(脚本/计数/对比断言),checker ≠ doer(异 subagent / 异模型对抗复审),绝不让 doer 自评糊弄(防古德哈特:别删测试、别外推甜区、别把旧模式换名当新发现)。
4. **绝不删人类知识**:落库一律保留好的、去重、补链、归档旧稿;起草 agent 不许顺手往 vault / 仓库写未审稿的草稿。
5. **数据真实,暗色不撕裂**:任何产出不许编造来源/数字;living surface 走冷色 zinc + light/dark 不撕。
6. **routine/cron 类只是分支**:除非任务本身是定时巡检,默认不把权重压到它上。

---

## 调用后的两个阶段

### 阶段 A —— 读 context,出草案,问一句话

1. **读当前 context**:这个 loop 要干的任务,通常就在当前对话里(刚讨论的研究/重构/审计/搜集)。若 context 里看不出来,只问一句:「这个 loop 要解决什么?一句话。」
2. **取当前时间**:`date +%s`(记 loop 起点;workflow 脚本里 `Date.now()` 被禁,时间一律主循环用 `date` 取,需要时通过 `args` 传进去)。
3. **起草 loop 方案**(下面六要素),用人话写给 founder 看,然后**用 AskUserQuestion 确认总时长 + 让他微调分层**。开场就是那句:「你要这个 loop 的话我建议跑 **X 小时**(够 ~N 轮),每轮我排了下面这个 dynamic workflow,你看行不行?」

**草案六要素**(缺一不可):
- **① 目标 + 完成判据**:这个 loop 干完算什么?判据怎么机器验证(对比断言 / 计数达标 / 0 警告 / 连续 K 轮无新增)?边界是什么(不许动什么、不许靠什么糊弄)?
- **② 建议总时长(预算)**:基于任务体量给一个推荐值 + 它够跑几轮。**这是 founder 唯一必须拍板的输入**。
- **③ 每轮的 layer 设计**:每个 layer 干什么 → 派几个 agent → 用什么模型 + effort。(默认模板见下方「分层库」,founder 在此基础上加减。)
- **④ 停止条件**:`达标` ∨ `连续 K 轮无新增(loop-until-dry,默认 K=2)` ∨ `时间预算耗尽` —— 三者**最先**满足即停。
- **⑤ 每轮产出 + 同步**:每轮 workflow 返回什么结构化结论、累积到哪(tmp ledger),每轮心跳给 founder 同步一行「本轮拿到啥 / 下轮干啥」。
- **⑥ 最终交付**:全部跑完后综合成什么(vault living surface / Obsidian 文案 / 一份结论),落哪。

**提问规范**(AskUserQuestion):
- Q1 **总时长**(必问):给 2h / 4h / 8h / 通宵 等选项 + Other 自定义。这是核心输入,放第一个。
- Q2 **分层是否照草案**(可选):给「照草案跑 / 我要改人数或模型 / 改 layer 数」。founder 选「改」就让他补一句具体怎么改。
- 其余(目标判据、停止条件)若 context 已足够清楚,**别问,直接在草案里写死并说明假设**,让 founder 一眼否决即可。

### 阶段 B —— 开跑 loop(主循环驱动)

确认后,主循环按下面这个驱动逻辑跑(伪码,实际用工具执行):

```
start  = date +%s
budget = 总时长(秒)
dry    = 0          # 连续无新增计数
round  = 0
ledger = []         # 累积结构化结论,落 $CLAUDE_JOB_DIR/tmp/loopd-ledger.md

while (date_now - start) < budget:
    round += 1
    # —— 一次心跳:跑一个完整 dynamic workflow ——
    res = Workflow(script=<本轮骨架,见下>, args={ roundNum: round,
                    priorSummary: 摘要(ledger), goal: 目标判据 })
    new = res.findings 里 ledger 里没有的(去重)
    ledger += new
    写 ledger 文件
    # —— 心跳收尾:同步 + 判停 ——
    同步给 founder:「第 round 轮:本轮 +len(new) 条,累计 X;下轮 …」
    if 达标(机器判据 over ledger):           break   # ① 达标
    if len(new) == 0: dry += 1                        # ② 没新增
    else:             dry = 0
    if dry >= K(默认2):                       break   # ② loop-until-dry
    # ③ while 条件本身就是时间预算

# 收尾:跨所有轮综合 → 最终交付(要素⑥)→ 同步 result:
```

**心跳 = 每完成一轮 dynamic workflow**:返回即同步 + 判停 + 决定下一轮。不要在一轮没跑完时插手。

**铺到很多小时 / 无人值守**:如果 founder 要 loop 横跨真实数小时或通宵(轮与轮之间需要等),用 `ScheduleWakeup` 在两轮之间排下次唤醒(把同一句 /loopd 指令回传),delay 选 1200–1800s 这种(别选 300s,见工具说明)。默认(在场、连续跑)则一轮接一轮,不必 sleep。

**别空转**:若任务很快达标 / 连续 dry,**早停**是对的——总时长是上限不是必须跑满。早停就早停,如实说。

---

## 本轮 dynamic workflow 骨架(模板,按 founder 的分层填槽)

每一轮都用 `Workflow` 跑这个形状。把 `<...>` 槽位按草案的 layer / 人数 / 模型填进去:

```js
export const meta = {
  name: 'loopd-round',
  description: '<本轮要解决的子问题>',        // 纯字面量,不许变量/拼接
  phases: [
    { title: 'L1-探' },                       // 一个 layer 一条;标题与 phase() 一致
    { title: 'L2-比/验' },
    { title: 'L3-综' },
  ],
}
// args = { roundNum, priorSummary, goal }
const prior = args?.priorSummary ?? ''
const FIND = { /* JSON Schema: 结构化发现,逼 StructuredOutput */ }
const VERD = { /* JSON Schema: 对抗核验判定 isReal/refuted */ }
const SYN  = { /* JSON Schema: 本轮综合结论 */ }

// —— L1 探:fan-out,数量/模型来自草案 ——
phase('L1-探')
const found = (await parallel(
  <RECON_AGENTS>.map((a, i) => () =>
    agent(`${a.prompt}
已知(勿重复):${prior}
硬上限:≤2 WebSearch + ≤1 WebFetch 后立刻出 StructuredOutput;任何工具不快速返回就基于已知收尾。`,
      { label: `探-${a.key}`, phase: 'L1-探',
        model: a.model /* 有 web 的用 'sonnet';纯推理可 'haiku' */, schema: FIND }))
)).filter(Boolean).flatMap(r => r.findings)

// —— L2 比/验:pipeline,每条发现一进来就对抗核验(异模型,prompt 让它 REFUTE)——
const verified = (await pipeline(found,
  f => agent(`对抗核验这条发现,默认可疑,尽力反驳;站不住就 refuted=true:${JSON.stringify(f)}`,
        { label: `验-${f.id ?? ''}`, phase: 'L2-比/验', model: 'sonnet', schema: VERD })
       .then(v => ({ ...f, verdict: v }))
)).filter(Boolean).filter(f => f.verdict?.isReal && !f.verdict?.refuted)

// —— L3 综:把本轮 verified + 历史综合成结构化结论;绝不写文件 ——
phase('L3-综')
const synth = await agent(
  `综合本轮存活发现 + 历史(${prior}),产出本轮结构化结论;只返回数据,绝不用 Write 写任何文件。`,
  { label: '综', phase: 'L3-综', model: 'opus', schema: SYN })

return { round: args?.roundNum, findings: verified, synthesis: synth }
```

**每个 agent 的 prompt 必带的护栏**(进每一条,不许漏):
- 机器可验证的产出格式(schema 已强制);
- 「数据真实,来源可溯,不编造;不确定就标 unverified」;
- web agent 的硬上限(≤2 搜 + ≤1 取 → 立即出结构化);
- 「只返回数据,**不要 Write 任何文件**」(防起草 agent 偷写 vault 造重复);
- 核验层显式「默认可疑、尽力反驳、站不住就判 refuted」。

---

## 分层库(草案默认值,按任务类型选一个起手)

**研究/搜集型**(对应 founder 的招牌打法):
- L1 探:`N` 个广搜 agent,按来源拆(X / GitHub / 论文 / 博客 / 官方…),`sonnet` + 硬上限。N 默认 6–10。
- L2 比/验:对所有发现聚类去重 → 多维评估 → 对抗核验(每条 1–3 票,`sonnet`)。
- L3 综:`opus` 单 agent 跨轮综合。

**实现/重构型**(对应「大任务用 dynamic workflow」纪律):
- L1 侦察:`2–3` 个 `sonnet` 读现状/定位改点。
- L2 设计:`opus` 出方案 + 异 agent 对抗评审。
- L3 实施:每个改点一个 `opus` agent,**`isolation:'worktree'`** 防并行改文件打架。
- L4 验收:脚本 checker(机器断言)+ 异模型只读复审抓真 bug。

**审计/找问题型**:
- 多模态广搜(按容器/内容/实体/时间各派一路,互相看不见)→ 对抗核验(多数票否决)→ 完整性批判 agent 问「还漏了什么」→ loop-until-dry。

founder 可在任意模板上加减人数、换模型、增删 layer——草案就是给他改的。

---

## 防卡死 / 防坑清单(每次开 workflow 必查)

- **`parallel()` 是栅栏**:必须等齐所有 agent 才返回,2–3 个 hang 住就「卡住不动」。能 `pipeline()` 就 pipeline;非要 barrier 的,web agent 一律有界(硬上限)+ 用 `sonnet`(haiku 弱模型做完搜索常不吐 StructuredOutput 挂死)。
- **诊断不靠猜**:卡住时读 workflow transcript 的 `journal.jsonl`,数 started vs `type:result`;空转最久、StructOut=0 的就是 hang 的那个。
- **抢救不重跑**:已完成结果全在 `journal.jsonl` 的 `type:result` 行,先抠出来落盘(一条不丢),再 `TaskStop`,只对缺的补跑。注意 workflow 返回是 `{summary,agentCount,logs,result:{...}}` 包装,真数据在 `result.xxx`。
- **起草 agent 偷写文件**:被要求「把全文放进 schema」时它常顺手 `Write` 进 vault 造重复——prompt 明令「只返回数据不写文件」,落库前再扫目标文件夹去重。
- **别让一个巨型 barrier 押注 flaky agent**:易 hang 的广搜要么有界、要么可被 journal 抢救。

---

## 什么时候用 / 不用

**用**:多轮才出质量的长任务——深度研究/对比选型、跨文件审计、大重构、找全某类问题、需要对抗复审收敛的活儿。
**不用**:一次 agent 就够的小问答、纯机械单步改动、或任务本身是定时巡检(那是 routine/cron,不是 loopd)。

---

## 收尾

- 每轮心跳同步一行;全部停后,跨轮综合 → 落最终交付(living surface / 文案 / 结论),保留旧好稿、去重、补链。
- 主循环最后写一行 `result:` 自含头条:跑了几轮、命中判据是哪条、最终交付落在哪。
- 若交付物有未来义务(flag 清理日 / job ETA),才考虑提一句 `/schedule`;否则收工。

参照记忆:`[[loop-engineering]]`(theOne=Harnessed-Driver,Ralph 脊椎 + 两级 checker)、`[[dynamic-workflow-hang-fix]]`(卡死修法)、`[[dynamic-workflow-for-intensity]]`(大任务分层纪律)。
