---
name: loopds
description: 把一个值得反复迭代的长任务,落地成一个「先问透、可机器验证、能跨会话持续跑」的自驱 loop。当 founder 说「loopds / 开个持续 loop / 把这件事做成能反复跑的 loop / 让它自己迭代到达标 / overnight 持续跑 / 把刚才研究的工作流固化下来」时使用。与 loopd 的最大不同:调用后**先知根知底地审讯**——把目标、完成判据、能不能机器验证、不许靠什么糊弄、预算、交付落点全部问透并回述确认,**确认前绝不开跑**;然后按任务形状选档(收敛型 = solo 单 agent reason-act-observe;开放/发散型 = 多 agent dynamic workflow + 自动生长),每一轮验证默认走「程序当裁判(curl/测试/编译器,以及 headless 渲染→截图/DOM 的视觉第0档,代码判而非模型自评),模型只当执行器」的第0档外部核验,产出累积进一个只增不退的外部账本;开放型还由一个自动生长引擎(facet 队列:确定性去重+多样性分箱+dry 兜底)自己生成下一步探索方向、泛化铺开不靠人手填,跑到「机器判据达标 / 连续无新增 / 生长枯竭 / 预算耗尽」最先满足才停,每轮回报 token 成本。这是把多轮 dynamic workflow + 搜索得出的「怎么写好 loop」结论,固化成的可复用持续版本(四根支柱:外部裁判+棘轮账本+客观停机+自动生长)。
---

# loopds —— 先问透、程序当裁判、能持续跑的自驱 loop

把一个长任务交给一个**不靠模型自我感觉良好、而靠它骗不过去的外部裁判逼着往前走**的 loop。

这个 skill 是一句话研究结论的产品化:**写好一个 loop 的全部功夫,不在「怎么让它继续转」,而在给它「一个骗不过去的外部裁判 + 一个只增不退的账本 + 一个客观的停机线」。** 焊死这三样,loop 自然每轮都真往前;少一样,它就是个自我感觉良好、烧钱空转的循环。

loopds 的签名动作只有一个:**开场先把你问到知根知底,目标和验证策略没钉死之前,一行活都不干。**

---

## 它和 loopd 哪里根本不同(founder 必看)

| | **loopd** | **loopds** |
|---|---|---|
| 开场 | 最小摩擦:只逼问「总时长」,其余直接写死假设让你一眼否决 | **知根知底审讯**:目标/判据/能否机器验证/不许靠什么/预算/交付,全问透 + 回述确认,**确认前不开跑** |
| 验证层 | 异模型对抗复审(模型当裁判,第2档,对自信幻觉无力) | **第0档外部裁判优先**:能 `curl`/跑测试/编译的,程序判;模型只当执行器,代码当裁判;判不了的才退模型,并标 `soft` |
| 账本 | tmp ledger 累积结论 | 同样累积,但区分**外部存储(真,棘轮)vs 外部真值(假,自产)**;每条标 `hard/soft` provenance |
| 停机 | 达标 ∨ 连续 dry ∨ 时间耗尽 | 同三条,但 dry 用**账本字节/行数的确定性变化**判,绝不信模型自报「我没进展了」 |
| 持续性 | 心跳 = 单会话内一轮 workflow 跑完;长跑靠 ScheduleWakeup | **跨会话持续**:按时长选驱动器(单会话 / Stop-hook / cron 起新会话读同一账本),状态全外置抗 compaction |
| 推进节奏 | 确认后一路跑到停 | **分步确认**:审讯→确认目标→出合同→确认→才开跑;每个 gate 你都能拦 |

一句话:**loopd 求快、求少打扰;loopds 求稳、求骗不过、求能持续。** 同一件事很急、context 已经很清楚 → 用 loopd;一件事值得反复迭代到真达标、要能跑很久、结论要经得起追问 → 用 loopds。

---

## 四根支柱(全部设计都从这里长出来)

**① 骗不过去的外部裁判(External Tier-0 Verifier)**
裁判的判决不能由产出答案的同一个模型给——那是机械自检,认识论上自己当自己裁判,没意义。判决要由**非语言模型**给:编译器、测试、形式校验器、跑代码、真值数据、`curl` 一个 URL。落地心法:**agent 只当执行器(跑命令、原样吐原始输出),代码当裁判(解析输出、判 pass/fail)。** 铁律:**产出某条断言的模型,永远不当它自己的终审。**

**② 只增不退的账本(Monotonic Ratchet Ledger)**
一个磁盘上的外部文件。要分清两层:它当**存储**是真外部(扛得住 compaction、agent 崩了能从 journal 救回、字节数 `wc` 说了算);它当**真值**不是外部(里面是模型自己写的,拿它当「新不新」的裁判 = 换壳的机械自检)。所以账本只用来**累积已被裁判验过的结论**,只增不退,每轮 ≥ 上一轮;绝不拿它当判官。

**③ 客观的停机线(Objective Stopping)**
`机器判据达标 ∨ 连续 K 轮账本无增长(dry) ∨ 预算耗尽`,三者最先满足即停。dry 必须用**确定性信号**判(账本行数/字节有没有变),不准用模型自报「没新东西了」。

**④ 自动生长(Self-directed Frontier Expansion)**
loop 不靠人手填「下一步搜什么」,而是**自己生成探索方向**:每轮综合层吐 `proposedNextFacets`(发现引出的增量方向)+ 一个 completeness-critic 层吐 `blindSpots`(类别级盲区),由一个**外置 facet 队列引擎**自动入队、自动弹出下一个方向。三个外部锚保证它真长、不自嗨、不坍缩:
- **确定性去重(novelty 外部锚)**:新方向用 bigram 相似度判重,**不让生成方向的同一模型当『新不新』的裁判**(否则又是机械自检)。
- **多样性分箱(防坍缩+泛化)**:方向按 `bin` 类别分箱,**冷 bin / 新类别优先**——先横向开新类别再钻深,避免在一个洞里越钻越窄。
- **dry 兜底**:即便某方向「看着新」,探完账本没长,dry 就把它毙掉。
引擎是纯函数、可测的(随 skill 附带 `autogrow.mjs` + `autogrow.test.mjs` + `drive.mjs`),判断权全在确定性代码不在模型。**没有这根,loop 只是把人喂的方向跑一遍;有了它,loop 才真的自驱生长、泛化铺开。**

---

## 选档:solo 还是 fan-out(开跑前必定,默认别一刀切重型)

> 业界共识(也是 loopd/loopds 分界):**大多数任务不需要一队 agent。单 agent + 好 prompt + 一个骗不过的检查器就够。** 重型 fan-out 只在任务真的发散、需要多视角对抗或泛化搜索时才划算。loopds 在阶段 0 就按**任务形状**定档,不默认上重型。

| | **solo 档(收敛型)** | **fan-out 档(发散/开放型)** |
|---|---|---|
| 什么任务 | 目标单一、有明确「做完」线:改到测试全绿 / 把页面调到像素 diff 达标 / 复现一张图到阈值 / 单文档迭代到判据 | 要广撒网、多来源、多视角对抗,或要泛化探索一个空间:研究 / 审计 / 找全部 bug / 跨领域综述 |
| 每轮形状 | **单 agent reason→act→observe**:想下一步→改→用第0档检查器验→没过就再来(可不开 `Workflow`,直接一个 agent 带 Bash/编辑工具) | 一个 `Workflow`:L1 探→L2/L3 验→L4 综→L5 盲区(本文「骨架」那套) |
| 支柱 ④ 自动生长 | **关掉**——收敛任务没有「下一步搜什么」的前沿,只有「离达标还差多少」 | **开启**——facet 队列自动生方向 |
| 三支柱①②③ | 全在:外部第0档检查器 + 棘轮账本(每轮只准更接近达标)+ 客观停机 | 全在 |
| 成本 | 轻、快、便宜 | 重、广、贵 |

**定档问一句就够**(阶段 0 里问):「这件事需要多视角对抗 / 泛化搜索吗?」——不需要 → solo;需要 → fan-out。**拿不准先 solo**,真撞到「一个 agent 视角不够」再升档。solo 档的「检查器」就是下面 Tier-0 手册里那几样(测试/编译/curl/视觉渲染断言),一样不许模型自评。

---

## 铁律(写死,任何一轮不许破)

1. **每轮 = 一次完整迭代,心跳 = 一轮跑完**。默认重型档每轮 = 一个 dynamic workflow(`Workflow` 工具,多 agent);**收敛型任务用 solo 档**(单 agent reason-act-observe,见「选档」)。无论哪档,①②③ 三支柱(外部裁判 / 棘轮账本 / 客观停机)一个不少;别拿重型 fan-out 去砸一个根本不需要对抗验证的小任务(视频教训:不懂就盲目堆 agent = 放大问题、烧钱空转)。
2. **能机器验证的,绝不让模型代劳**。凡能 `curl`/跑测试/编译/计数判定的,走第0档程序;判不了的才退模型并标 `soft`。doer ≠ checker,产出断言的模型不当自己终审。
3. **总时长是预算/护栏,不是工期承诺**。到点收尾;早达标就早停,如实说,绝不空转凑满。
4. **绝不在空输入上编造**。某层 verify 后存活 0 条,就跳过综合、如实记空轮,**绝不无中生有**(历史上 synth 在 recon 全挂时编造过假发现+假 arXiv 号,必须用非空 gate 挡死)。
5. **绝不删人类知识**:落库保留好稿、去重、补链、归档旧稿;起草 agent 不许顺手往 vault/仓库写未审稿。
6. **数据真实,来源可溯**:不编造来源/数字;不确定标 unverified;living surface 走冷色 zinc + light/dark 不撕。
7. **状态全外置**:目标/合同/账本/计数全落盘文件,不靠 context 记忆(8h 内必 compaction)。
8. **自动生长不许人手填方向**:「下一步搜什么」由 facet 队列引擎从本轮 `proposedNextFacets`+`blindSpots` 自动产生;novelty 用确定性去重 + dry 判,绝不让生成方向的模型自判新不新(认识论同①)。人手填方向只在 loop 起点给一个种子 facet。

---

## 阶段 0 —— 知根知底(签名特性,绝不跳过)

调用后**第一件事不是干活,是审讯**。目的是把这个 loop 的「合同」钉死到可机器验证。先读当前 context 把能推断的填好,**只就真正不确定、且影响验证策略的点发问**,然后**回述确认**,确认通过才进阶段 1。

**先取时间锚点**:`date +%s`(记 loop 起点;workflow 脚本里 `Date.now()` 被禁,时间一律主循环用 `date` 取,需要时通过 `args` 传)。

**审讯要问透的六件事**(能从 context 推断的先写成草案默认值,标「我的假设」让 founder 一眼否决;推断不出、又影响验证策略的,才用 `AskUserQuestion` 问):

1. **真正的目标 + 完成判据**:这个 loop 干完到底算什么?判据怎么**机器验证**(对比断言 / 计数达标 / 0 警告 / 测试全绿 / 连续 K 轮无新增)?
2. **★这个领域有没有第0档 oracle**(决定整套验证策略,必须问清):
   - **有**(代码/数学/可拉取的外部事实):产出能 `编译/跑测试/curl/查 API` 验真 → 验证主力走程序,模型只当执行器。
   - **没有**(纯主观:文案好不好、研究新不新):没有金标裁判 → 退异族模型 + 多来源三角 + 人在残差,产出一律标 `soft`,并尽量把子判断改写成程序能答的形式。
3. **不许靠什么糊弄(古德哈特边界)**:不许动什么文件?不许删测试?不许把旧模式换名当新发现?不许外推「甜区」?
4. **预算 + 在不在场**:跑多久(运行预算上限,**founder 唯一必填**)?在场连续跑,还是 overnight/跨会话无人值守?——这决定驱动器选哪个。
5. **交付落点**:跑完综合成什么(vault living surface / Obsidian 文案 / 一份结论 / 一批代码改动),落哪。
6. **已知 prior**:已经知道什么、已有什么成果,避免重复劳动(写进账本初值当 loop 的起点)。
7. **任务形状 → 选档**(决定 solo 还是 fan-out,见「选档」):这件事是**收敛型**(单一目标、有明确做完线 → solo 单 agent)还是**发散/开放型**(要多视角对抗 / 泛化搜索 → fan-out workflow + 自动生长)?拿不准默认 solo,撞墙再升档。

**提问规范**(`AskUserQuestion`,一次最多 4 问,别连环轰炸):
- 必问:**预算时长**(给 2h/4h/8h/通宵 + Other);若 context 看不出目标,加问一句「这个 loop 要解决什么,一句话」。
- 强烈建议问:**这领域有没有第0档 oracle**(给「有,能跑测试/编译/查证」「没有,纯主观判断」「部分有」)——这条直接决定验证层怎么搭,别替 founder 猜。
- 其余(古德哈特边界、交付落点)若 context 够清楚,**写进草案默认值并标假设**,让 founder 否决即可,不必单独问。

**回述确认 gate**:问完后,用人话把合同回述一遍给 founder:「我理解这个 loop 是:**目标 X,达标判据 Y(用 Z 机器验证),不许 W,预算 T,跨会话靠 D,产出落 P**。对不对?」——**得到确认才进阶段 1**。不确认就改。这就是「先把目标搞清楚,我们再做下一步」。

---

## 阶段 1 —— 出 loop 合同,确认分层

审讯确认后,把合同补全成可执行方案,再让 founder 看一眼分层:

**统一 run-id 目录**(采纳自 gnhf 对比研究 `data/gnhf-vs-loopds-a3`,类比 gnhf 的 `.gnhf/runs/<runId>/`):这轮 loop 落盘的一切 —— 合同、账本、facet 队列、每轮原始记录 —— 都放进同一个可按名字寻址的目录 `$CLAUDE_JOB_DIR/tmp/loopds-runs/<runId>/`(`<runId>` 用「日期+一句话 slug」,如 `2026-07-04-novyx-encap-gap`),而不是散落在 `tmp/` 下的一堆 `loopds-*` 扁平文件。好处:一次会话死掉后,靠 `<runId>` 就能整包找回并续跑,不用从零散文件猜状态;`drive.mjs` 的 `LOOPDS_DIR` 环境变量本来就认这个目录,这纯粹是命名约定,不需要改 `drive.mjs`/`autogrow.mjs` 一行代码。目录里固定放:
- `loopds-contract.md`(合同)、`loopds-ledger.md`(账本)、`loopds-facets.json`(自动生长状态)—— 路径同下方主循环伪码,只是加了 `loopds-runs/<runId>/` 这层。
- `transcripts/round-<n>.json`:每轮的原始 `res`(`Workflow` 的完整返回值,不只是抠出来的 `takeaways`),主循环每轮结束后落盘一份,类比 gnhf 的 `iteration-<n>.jsonl`。账本是「棘轮后的结论」,transcripts 是「这轮到底发生了什么」的原始记录,两者互补:账本丢字段能从 transcript 补,transcript 大不需要每次全读。

**Loop 合同(落盘 `$CLAUDE_JOB_DIR/tmp/loopds-runs/<runId>/loopds-contract.md`)**:
- **目标 + 机器判据**(阶段 0 钉死的)
- **验证策略**:每类产出走哪档裁判(第0档程序 / 异族模型 / 三角),`hard/soft` 怎么标
- **每轮 layer 设计**:每层干什么 → 派几个 agent → 什么模型 + effort(模板见「分层库」)
- **停机线**:达标 ∨ 连续 K 轮 dry(默认 K=2,用账本增量判) ∨ 预算耗尽
- **驱动器**:单会话 / Stop-hook / cron(见阶段 2)
- **账本与交付**:账本落点 + 最终综合成什么落哪

**分层只问一句**(`AskUserQuestion` 可选):「照草案跑 / 改人数或模型 / 改 layer 数」。选改就让 founder 补一句具体怎么改。确认后开跑。

---

## 阶段 2 —— 开跑:每轮一个 dynamic workflow,按时长选驱动器

**先按「在不在场 + 跑多久」选驱动器(这是 loopds 的持续性所在)**:

| 场景 | 驱动器 | 怎么续轮 |
|---|---|---|
| 在场、几十分钟~2h | **单会话** | 一轮 workflow 跑完即下一轮,心跳 = workflow 完成通知 |
| 在场、数小时,轮间要等 | **ScheduleWakeup** | 两轮之间排唤醒(回传同一句 loopds 指令),delay 1200–1800s(别选 300s) |
| overnight / 跨会话 / 要最干净的 context | **cron + 新会话**(最稳的长跑) | `launchd`/`cron` 每隔一阵起一个**全新会话**,各自 `Read` 同一个账本当 prior、干一轮、`append` 回账本。每轮 context 干净、天然分段、自带「读账本→干→写账本」棘轮 |

> 单会话用 Stop-hook 自动续轮也行,但默认连续阻止上限是 8 次(`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`),长跑必须在 settings.json 的 `env` 里调高;且单会话扛满数小时后 context 会越来越脏。**真要跑很久,优先 cron 起新会话读同一账本**,而不是指望一个会话扛满。

**主循环驱动逻辑**(伪码,实际用工具执行):

```
start  = date +%s ; budget = 预算(秒) ; prevTok = 0 ; N = 0 ; consecutiveErrors = 0
RUNDIR = $CLAUDE_JOB_DIR/tmp/loopds-runs/<runId>      # 统一 run-id 目录,见上
ledger = $RUNDIR/loopds-ledger.md   # 棘轮,只增不退
facets = $RUNDIR/loopds-facets.json # 自动生长状态(facet 队列),起点放一个种子 facet
export LOOPDS_DIR=$RUNDIR
# drive.mjs = autogrow 引擎的确定性驱动器(随 skill 附带:autogrow.mjs + drive.mjs)

while (date_now - start) < budget:
    N += 1
    node drive.mjs pick                          # ④ 引擎自动弹下一方向 → 写 current-facet.txt(绝不手填)
    size0 = wc -c ledger
    try:
        res = Workflow(scriptPath=<本轮骨架>)     # 骨架 return 带 tokensSpent=budget.spent()(本回合累计输出 token)
    catch (infraErr):
        # —— 基础设施错误指数退避(采纳自 gnhf 对比研究 data/gnhf-vs-loopds-a3;与下面
        # 的 dry/circuit-breaker 是两类失败:dry = 跑完了但没长东西,这里 = 根本没跑完,
        # Workflow 调用抛错/API 500/限流)。任意一轮成功完成(不论 dry 与否)清零计数。
        consecutiveErrors += 1
        delayMs = node drive.mjs backoff consecutiveErrors   # 60_000 * 2^(n-1),与 gnhf 一致
        同步 founder:「第 N 轮基础设施错误(连续第 consecutiveErrors 次):infraErr;退避 delayMs 后重试」
        sleep(delayMs) ; N -= 1 ; continue        # 不消耗轮次预算,只消耗时间预算
    consecutiveErrors = 0                          # 本轮 Workflow 调用本身成功,清零
    write(res → $RUNDIR/transcripts/round-N.json)  # 原始记录,类比 gnhf 的 iteration-<n>.jsonl
    append(res.takeaways → ledger, 标 hard/soft)  # 主循环确定性落盘,不让 agent 写文件
    sizeN = wc -c ledger ; grew = sizeN - size0
    # —— 成本回报(cut 3):本轮 token = 累计差;按已用轮均速估预算内还够几轮 ——
    roundTok = res.tokensSpent - prevTok ; prevTok = res.tokensSpent
    avgTok   = res.tokensSpent / N                 # 至今每轮平均 token
    elapsed  = date_now - start ; avgSec = elapsed / N
    roundsLeft = floor((budget - elapsed) / max(avgSec, 1))
    同步 founder:「第 N 轮[bin]:hard +a/soft +b,账本增 grew B;本轮约 roundTok tok、累计 res.tokensSpent tok;按当前均速预算内还够约 roundsLeft 轮;下轮引擎自动选 …」
    if roundTok > 3 * avgTok 或 roundsLeft < 1:  提醒成本异常/逼近预算,考虑收尾  # 12h 空跑教训
    node drive.mjs ingest res.json grew [deadlinePassed]  # ④ 喂回 nextFacets+blindSpots、确定性去重入队、记 dry、判停
    if 机器判据达标(over 账本):                  break   # ① 达标
    if drive 报 STOP(reason=dry):                break   # ② 连续无增长
    if drive 报 STOP(reason=queue-empty):        break   # ④ 生长枯竭(再无新方向可探)
    # ③ while 条件即时间预算

# 收尾:跨轮综合 → 最终交付 → result:
```
> **token 成本从哪来**:dynamic workflow 脚本里 `budget.spent()` 返回本回合至今的累计输出 token(主循环 + 所有 workflow 共享池),骨架把它 `return` 出来,主循环算差得每轮成本——确定性、不靠估。solo 档没有 workflow,用每轮 wall-clock + 自报轮数估「还够几轮」。founder 设了 `+Nk` token 预算时,同时对 `budget.total` 报「已花/还剩」。

**心跳 = 每完成一轮 dynamic workflow**:返回即同步 + 判停 + 决定下一轮。一轮没跑完不插手。早达标/连续 dry 就**早停**,总时长是上限不是必须跑满。

---

## 本轮 dynamic workflow 骨架(模板:第0档验证版)

每轮用 `Workflow` 跑这个形状。**串行编排原则**:层间串行、层内 fan-out;`pipeline` 优先于 `parallel` 栅栏;verify 紧贴 propose;裁判分档路由(便宜的先筛,贵的只给存活者);最后一层 completeness critic 扩边界。
**解析器纪律(踩过的雷,务必遵守)**:schema 一律 `JSON.parse('单行JSON')`;凡 `await` 先单独赋值一行,**绝不** `(await …).filter()` 多行链式;agent opts 单行。

```js
export const meta = {
  name: 'loopds-round',
  description: '<本轮要解决的子问题>',         // 纯字面量,不许变量/拼接
  phases: [ { title: 'L1-探' }, { title: 'L2-硬验' }, { title: 'L3-软验' }, { title: 'L4-综' }, { title: 'L5-盲区' } ],
}

const LEDGER = args.ledgerPath
const goal = args.goal

const FIND = JSON.parse('{"type":"object","additionalProperties":false,"required":["findings"],"properties":{"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","claim","check","url","confidence"],"properties":{"id":{"type":"string"},"claim":{"type":"string"},"check":{"type":"string","description":"能机器验证这条的命令/手段,无则写 none"},"url":{"type":"string"},"confidence":{"type":"string","enum":["high","medium","low"]}}}}}}')
const PROBE = JSON.parse('{"type":"object","additionalProperties":false,"required":["raw","exitCode"],"properties":{"raw":{"type":"string","description":"命令完整原始 stdout,严禁总结/判断"},"exitCode":{"type":"integer"}}}')
const VERD = JSON.parse('{"type":"object","additionalProperties":false,"required":["isReal","refuted","reason"],"properties":{"isReal":{"type":"boolean"},"refuted":{"type":"boolean"},"reason":{"type":"string"}}}')
const SYN = JSON.parse('{"type":"object","additionalProperties":false,"required":["takeaways","proposedNextFacets","dryFlag"],"properties":{"takeaways":{"type":"array","items":{"type":"string"}},"proposedNextFacets":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["facet","bin"],"properties":{"facet":{"type":"string"},"bin":{"type":"string"}}},"description":"由本轮发现引出值得下轮深挖的增量方向,每条标 bin 类别"},"dryFlag":{"type":"boolean"}}}')
const CRIT = JSON.parse('{"type":"object","additionalProperties":false,"required":["blindSpots"],"properties":{"blindSpots":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["facet","bin","why"],"properties":{"facet":{"type":"string"},"bin":{"type":"string"},"why":{"type":"string"}}},"description":"账本完全没碰、但真高手在用的类别级大盲区"}}}')

// —— L1 探:fan-out,先读账本只找相对它新的;数量/模型来自合同 ——
phase('L1-探')
const reconRaw = await parallel(<RECON>.map((a, i) => () => agent(
  "先用 Read 读账本(勿重复已有):" + LEDGER + "\n然后就[" + a.who + "]来源,针对本轮子问题做有界广搜。目标:" + goal + "\n硬上限:≤2 WebSearch + ≤1 WebFetch 后立刻出 StructuredOutput;每条 finding 的 check 字段写出「能机器验证它的命令」(如 arXiv API/curl/跑测试),没有就 none。数据真实不编造、URL 不伪造。只返回数据,不写文件。",
  { label: "探-" + a.key, phase: 'L1-探', model: a.model || 'sonnet', schema: FIND })))
const found = reconRaw.filter(Boolean).flatMap(r => (r.findings || []))
log("L1 探:" + found.length + " 条")

// —— L2 硬验(第0档):agent 只当执行器跑命令,JS 当裁判;能机器验的全走这里 ——
const probable = found.filter(f => f && f.check && f.check !== 'none')
const probedRaw = await pipeline(probable, (f, _o, i) => agent(
  "你只是执行器,严禁判断真假。用 Bash 跑下面这条核验命令,把【完整原始 stdout】和退出码原样返回,不许总结:\n" + f.check + "\n(若是 arXiv 号核验,用 curl -sL 'https://export.arxiv.org/api/query?id_list=<号>' —— 必须 https,http 会 405)",
  { label: "硬验-" + (f.id || i), phase: 'L2-硬验', model: 'sonnet', schema: PROBE })
  .then(r => ({ f: f, hardPass: !!(r && r.exitCode === 0 && r.raw && r.raw.length > 0 && r.raw.indexOf('<entry>') !== -1) })))
const hard = probedRaw.filter(Boolean).filter(x => x.hardPass).map(x => ({ ...x.f, tier: 'hard' }))
log("L2 硬验:第0档过 " + hard.length + " / " + probable.length)

// —— L3 软验:无第0档手段的残渣,退异族/对抗模型默认反驳,标 soft ——
const soft0 = found.filter(f => f && (!f.check || f.check === 'none'))
const softRaw = await pipeline(soft0, (f, _o, i) => agent(
  "对抗核验这条(默认可疑,尽力反驳,站不住 refuted=true)。注意:这条没有程序能验,你的判定只是 soft 信号:\n" + JSON.stringify(f),
  { label: "软验-" + (f.id || i), phase: 'L3-软验', model: 'sonnet', schema: VERD })
  .then(v => ({ ...f, tier: 'soft', verdict: v })))
const soft = softRaw.filter(Boolean).filter(f => f.verdict && f.verdict.isReal && !f.verdict.refuted)
log("L3 软验:存活 " + soft.length)

// —— L4 综:只在非空输入上综合;由主循环把 takeaways append 进账本(标 hard/soft)——
const survived = hard.concat(soft)
let synth = null
let crit = null
if (survived.length > 0) {
  phase('L4-综')
  synth = await agent(
    "用 Read 读账本了解历史:" + LEDGER + "\n综合本轮存活发现 + 历史,产出 takeaways(每条标 [hard]/[soft] + 来源)+ proposedNextFacets(发现引出值得下轮深挖的增量方向,每条标 bin 类别)。本轮存活(唯一可用素材,绝不另搜或凭记忆补):" + JSON.stringify(survived) + "\ndryFlag 标本轮是否几乎无相对账本的新增。只返回数据,绝不写文件。",
    { label: '综', phase: 'L4-综', model: 'opus', schema: SYN })
  // —— L5 盲区:completeness-critic 产类别级盲区,喂自动生长引擎扩边界 ——
  phase('L5-盲区')
  crit = await agent(
    "你是 completeness-critic。Read 账本:" + LEDGER + "\n纵观整个主题,账本已覆盖的之外,真高手在用、而账本完全没碰的【类别级大盲区】有哪些?每条给一个新 bin 类别短标签 + facet(可深挖方向)+ why。只列真盲区,别把账本已有的换名。只返回数据,不写文件。",
    { label: 'critic', phase: 'L5-盲区', model: 'opus', schema: CRIT })
} else {
  log("本轮存活 0 条,跳过综合+critic,绝不在空输入上编造")
}
// proposedNextFacets + blindSpots 交回主循环喂给 drive.mjs(autogrow 引擎)自动选下一方向
return { round: args.roundNum, hard: hard, soft: soft, takeaways: synth ? synth.takeaways : [], proposedNextFacets: synth ? synth.proposedNextFacets : [], blindSpots: crit ? crit.blindSpots : [], dryFlag: synth ? synth.dryFlag : true, tokensSpent: budget.spent() }
```

主循环拿到返回后,把 `synthesis.takeaways` 去重后 **append 进账本文件**(标 `hard/soft`),再判停。**append 由主循环做(确定性),不让 workflow 内 agent 写文件**(防偷写造重复 + socket 写易碎)。

---

## Tier-0 验证手册(把主观判断改写成程序能答的)

> 心法:**能被嘴皮子说服的检查都不算外部;把它改写成程序能 yes/no 的检查。**

| Oracle | 用在 | 怎么接 |
|---|---|---|
| **跑代码/编译器** | loop 产出脚本/代码 | agent 跑 `node --check`/`tsc`/`python -c`,**JS gate 在退出码 0** |
| **测试** | 有预期行为 | agent 跑 `pytest -q`/`bun test`,**JS 解析 "N passed, M failed",gate 在 M==0** |
| **curl 一个 URL** | 核外部事实(论文/API/价格) | arXiv 用 `curl -sL 'https://export.arxiv.org/api/query?id_list=<号>'`(**必须 https,http 会 405**),**判 `<opensearch:totalResults>≥1` 或 entry title≠Error**;一般 URL `curl -sI` 看 200 |
| **形式校验/schema** | 结构合法性 | StructuredOutput 强制 schema 已是机械校验,畸形直接打回 |
| **真值数据** | 有 fixture | agent/脚本 diff 输出 vs 真值文件 |
| **渲染/运行产物**(视觉) | 产出是页面/UI/可视化/能跑的东西 | `node vischeck.mjs render <html> out.png` 用 headless Chrome 真渲染;**先看它跑没跑起来**——`nonblank out.png` 判退出码 + 截图非空(白屏/崩了→fail) |
| **视觉结构断言**(视觉) | 产出是页面/DOM | `node vischeck.mjs domcheck <html> --inc '<canvas' --exc 'Uncaught' --min 'sel=3'`,**代码判元素存在/计数/无报错文本**(不靠肉眼也不靠模型) |
| **像素 diff**(视觉) | 有参考图要比对 | `node vischeck.mjs diff out.png ref.png 0.02`(不同像素占比≤2% 才过,需 ImageMagick);没参考图就退化到上面两档 |

**⚠️ 执行器也会撒谎**:「agent 跑 curl」仍有缝——它可能没跑、直接编造 raw 输出。所以:
- **第0档最干净的落点是确定性驱动器(cron/Stop-hook 的 bash),那里命令与裁判之间没有模型**(如 dry 判定用 `wc -c` 就是零缝隙)。能放驱动器跑的硬核验就放驱动器。
- 必须在 workflow 里跑的:让 agent **返回原始输出**(不是 yes/no)+ **JS 判**,把模型降成哑执行器;高风险的可让**两个不同家族 agent 各跑一遍对比**压低伪造概率。
- **纯主观无 oracle**(论证严不严谨、文案好不好):curl 不了,只能异族模型 + 三角 + 人在残差,一律标 `soft`,别假装 hard。

**🎯 视觉第0档怎么做对(这是 loopds 之前的盲区,务必照红线)**:产出是视觉的(页面/UI/图/3D)时,流程是 **render/run → 截图或取 DOM → 由代码判**。判决只能是这三类之一,**绝不能是「让模型看自己的截图打 9 分」**——那是把第3档自评伪装成验证,正是 loopds 要根除的(对照:意见领袖的 loop 案例多用模型自评分,看着像验证实则模型当自己裁判):
- **像素 diff**(有参考图):`vischeck.mjs diff out.png ref.png <阈值>`,不同像素占比超阈值即 fail。
- **结构断言**(无参考图但有结构):`vischeck.mjs domcheck`,断言关键元素在、计数够、无 `Uncaught`/`Error` 文本——**视觉任务最常用、最稳的一档**。
- **非空/能渲染**:`vischeck.mjs nonblank`,挡「渲染成白屏/崩了」。
- **纯生成型视觉没金标**(如「做张好看的缩略图」):没有参考图、没有硬结构 → 要么把「好看」拆成代码能答的子断言(文字在 120px 缩略下 OCR 能还原=可读、对比度≥阈值、关键元素都在),要么老实标 `soft`,别让模型给自己的审美打分冒充 hard。

随 skill 附带 `vischeck.mjs`(+ `vischeck.test.mjs` 测判决逻辑,22/22):`render/dom/nonblank/domcheck` 用 macOS 自带的 **Chrome headless + sips,零额外安装**;`diff` 需 `brew install imagemagick`,没装会明确报错并引导改用结构断言。判决全在确定性代码里,退出码驱动 gate,中间没有模型。

---

## 自动生长引擎(第四根支柱的落地:facet 队列)

随 skill 附带三个文件(纯函数 + 确定性驱动 + 测试),让「下一步搜什么」由 loop 自己长出来:

- **`autogrow.mjs`**:纯函数引擎。`ingest(state,{proposedNextFacets,blindSpots})` 把本轮产出的新方向**确定性去重**后入队(bigram 相似度 ≥ 阈值即判重——novelty 的外部锚,不让模型自判);`pickNext(state)` 按**冷 bin / 新类别优先**自动弹下一方向(多样性防坍缩、强制横向泛化);`recordRound` 记 dry(账本没长就累加);`shouldStop` 判停(budget ∨ dry ∨ queue-empty)。
- **`drive.mjs`**:确定性驱动器。`node drive.mjs pick` 弹方向写 `current-facet.txt`;`node drive.mjs ingest <res.json> <grewBytes>` 喂回本轮产出 + 记 dry + 判停。
- **`autogrow.test.mjs`**:第0档自检。`node autogrow.test.mjs` 必须全绿(去重/多样性/盲区优先扩类/dry兜底/端到端跨类别),改引擎后先跑它。

**为什么这样设计**(全部是被辩论锤过的结论):
- novelty 用**确定性去重**而非模型自判——「这方向新不新」让生成它的同模型说了算 = 机械自检,认识论同支柱①。
- 多样性**分箱**而非单队列——否则 loop 会在最初那个方向上越钻越窄(curriculum collapse),失去泛化。
- **dry 当最终兜底**——去重只挡字面重复,挡不住「换皮的旧内容」;探完账本不长就毙掉,客观信号说了算。
- 引擎是 loop 之外的**确定性代码**,判断权不在任何 agent 手里;agent 只负责「产方向」(proposedNextFacets/blindSpots),「选方向」是引擎的事。

## 分层库(合同默认值,按任务类型起手)

**研究/搜集型**:L1 探 = 6–10 个广搜 agent 按来源拆(X/GitHub/论文/博客/官方),`sonnet`+硬上限 → L2 硬验(能查证的走 curl/API)→ L3 软验(残渣对抗)→ L4 `opus` 综合。
**实现/重构型**:L1 侦察 2–3 个 `sonnet` 定位 → L2 设计 `opus`+对抗评审 → L3 实施每改点一个 `opus`,**`isolation:'worktree'`** 防并行打架 → L4 验收 = **跑测试/编译(第0档)** + 异模型只读复审。
**审计/找问题型**:多模态广搜(按容器/内容/实体/时间各一路,互相看不见)→ 对抗核验多数票否决 → completeness critic 问「还漏哪类」→ loop-until-dry。

founder 可在任意模板加减人数/换模型/增删 layer。

---

## 防卡死诊所(每次开 workflow 必查)

- **`parallel()` 是栅栏**:2–3 个 agent hang 住就「卡住不动」。能 `pipeline()` 就 pipeline;非要 barrier 的,web agent 一律有界(硬上限)+ 用 `sonnet`(haiku 做完搜索常不吐 StructuredOutput 挂死)。
- **诊断不靠猜**:卡住读 workflow 的 `journal.jsonl`,数 started vs `type:result`,空转最久、StructOut=0 的就是 hang 的那个。
- **抢救不重跑**:已完成结果都在 `journal.jsonl` 的 `type:result` 行,先抠出来落盘(一条不丢),再 `TaskStop`,只补缺的。返回是 `{summary,agentCount,logs,result:{...}}` 包装,真数据在 `result.xxx`。
- **起草 agent 偷写文件**:prompt 明令「只返回数据不写文件」,落库前扫目标文件夹去重。
- **绝不让巨型 barrier 押注 flaky agent**:易 hang 的广搜要么有界、要么可被 journal 抢救。

---

## 收尾

- 每轮心跳同步一行;全部停后跨轮综合 → 落最终交付(living surface/文案/结论/代码),保留旧好稿、去重、补链。
- 主循环最后写一行 `result:` 自含头条:用哪档(solo/fan-out)、跑了几轮、命中判据是哪条、hard/soft 各多少、**累计 token 成本**、最终交付落哪。
- 交付物若有未来义务(flag 清理日 / job ETA)才提 `/schedule`;否则收工。

参照记忆:`[[loop-engineering]]`、`[[elite-loop-engineering-research-and-loopd-v2]]`(本 skill 的结论来源)、`[[dynamic-workflow-hang-fix]]`、`[[workflow-parser-multiline-object-bug]]`(解析器两雷)、`[[lorevik-memory-system-real-and-wired]]`(archive 外置调现成的别重造)。

---

## 增强 v2（2026-06-21 · 焊进收尾同步 + 停机/隔离补强）

> 这节是对上面四支柱的**补强**,不改它们已对的设计。新增:收尾同步契约(治「跑完不冒到控制台」的缝)+ circuit breaker + 硬 wall-clock 超时 + 隔离安全姿态。来源:Simon Willison《Designing agentic loops》+ Claude Code agent-loop docs + Lorevik 实战(2026-06-21 surface 漏同步事故)。

### ⑤ 收尾同步契约（每轮收尾必做 · 治「漏在缝里」）

loop 跑完不是写个 tmp 账本就完——**收尾要把本轮成果写到它真正的家 + 让 founder 在控制台看见**。每轮收尾按序做:

1. **写支柱的家**(知识库):`<支柱>/reports/<日期>--<run-id>.md`(收口报告)+ append 一行 `<支柱>/LOG.md` + append 一条 `_总账-INDEX.md` 的支柱时间线。时间线七段固定:**问题/目标 → 发起时间(精确到秒,如 `2026-06-21T19:46:11+08:00`)→ 时长(真实,如 `45m`)→ 成果落地了什么 → 完成了什么 → 现在有什么变化 → 下一步**;有 commit / 待 founder 就写进去。
2. **同步进控制台 surface**(机械、别手搬):跑
   `node ~/.claude/skills/loopds/sync-surface.mjs <支柱号 如 01>`
   它幂等地把总账新 entry 转成 JSON、补进 `tech-console/data.json`(APP vault + 知识库两份)、删运行时 state、且已过 surface 校验。**founder 刷新控制台即见。**
3. **canonical 只提名**:值得长久沉淀的结论只在 report `durable:` 段提名,编排者去重后升级,**agent 不直写 `_canonical`**。

> ★ 为什么必须有这步:2026-06-21 实测,agent 把活同步进了知识库(markdown 总账),却**漏了 surface 的 data.json**(另一个 vault、另一种格式),控制台看不到。根因 = 「surface 同步」被当成已存在却从没造。本契约 + `sync-surface.mjs` 焊死这条,**再不漏**。

### ⑥ circuit breaker（停机线补强 · 别空转烧 token）

四支柱③的客观停机 = `达标 ∨ dry ∨ 预算`。**补一条**:连续 **K 轮(默认 3)** 第0档 hard 判据**全失败** → 立即停,不再续跑;停时**标回滚意向**(本轮改动留自己分支不合) + 在 report `needs_founder` 上呈 founder。理由:反复撞同一面墙的 loop 是在制造自信错误 + 烧钱,该「停手上呈」,不该硬转。

### ⑦ 硬 wall-clock 超时（防孤儿）

每个 run 设一个**硬墙钟上限**(随预算给,如 8h),到点无条件停 + 收尾上呈——**防长跑后台任务变孤儿永远挂着**。这是预算停机的兜底:即使账本还在动也照停。

### ⑧ 隔离 / 安全姿态（长跑自治尤其）

- **worktree 隔离**:从新 main 开自己的 feature 分支干(`--worktree` / `isolation:worktree`);**只 `git add -- <精确路径>`,绝不 `add -A` / `stash` / `checkout`,绝不 push**;共用文件只 handoff 提名,不直接动。
- **预算上限**:花钱的能力(真扣款 / 外部 API)设极低上限或只给 test 凭据;真扣款 / go-live = founder 门。
- **风险动作不自决**:钱 / 公开发布 / 法律 / 删除 四门只提名等 founder;安全(出口 PII / 鉴权)移交 security-warden + `SECURITY_LANE_APPROVED`,不自碰。
- **工具偏好**:shell 优先(LLM 擅长 shell,第0档裁判好解析);别为单例打补丁,例子 = 泛化。

> 一句话:loop 不只是「继续转」——它要**有骗不过的检查器(①)、只增的账本(②)、客观停机+断路器(③⑥⑦)、自动生长(④)、跑完真同步到家和控制台(⑤)、且在隔离里安全地跑(⑧)**。少一条,它就退化成自我感觉良好、烧钱、还漏在缝里的循环。
