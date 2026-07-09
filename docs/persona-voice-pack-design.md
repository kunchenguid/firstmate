# 可自定义人设（Persona Voice Pack）设计草稿

状态：待船长评审。本文只是设计规范，不含落地代码。

## 1. 背景与目标

First Mate 会分发给其他同学使用。当前的对外身份（first mate / captain / 航海腔）是写死的。
若直接把它换成海绵宝宝这类主题，会给没看过该作品的同学增加理解成本。

目标：把"对外人设"做成**可选、默认关闭、用户可自定义**的一层皮肤，做到：

- 默认出厂行为与今天完全一致，任何不主动开启的人零感知、零成本。
- 想要海绵宝宝、或任意自定义主题的人，在本地配置里开一个"voice pack"，只对自己生效。
- 主题只改"嗓音"，绝不碰系统运转的骨架。

## 2. 核心原则：只改嗓音，不改机器

系统里有两层词汇，必须分清：

- **机制词汇层**：`crewmate`、`scout`、`secondmate`、`watcher`、`ship`、`teardown`、任务 id、`state/*.meta` 字段、`data/backlog.md` 格式等。写死在脚本、AGENTS.md、状态文件里，是骨架。同学排查问题、读脚本靠的就是这套词。**这层永不主题化。**
- **对外嗓音层**：我在对话里如何称呼船长、用什么口吻、把露出的角色叫成什么。今天被硬编码成 first mate/captain/航海腔，纯表现。**主题只活在这一层。**

海绵宝宝映射（crewmate→海绵宝宝、scout→珊迪……）内部永远还是 `crewmate`/`scout`，只有在对开启皮肤的用户说话时才换名。没开的人碰不到这层。

## 3. 关键发现：人设的暴露面比"全量改名"小得多

评审 AGENTS.md 第 9 节（Escalation and captain etiquette）后确认：**默认情况下我根本不该对船长说出 crewmate/scout/ship/task id/worktree 这些内部词**，而是"用结果说话"——"这项工作可以评审了 / 被卡住了 / 需要你拍板"。

这意味着"crewmate → 海绵宝宝"这类改名，在正常汇报里既不会出现 `crewmate` 也不会出现 `海绵宝宝`。所以 voice pack 分成两级：

- **一级（始终生效）——身份与口吻**：如何称呼船长、我如何自称、整体语气/口头禅/点缀风格。这一级替换的正是现在"称呼 captain + 航海点缀"那块，是主题的主战场。
- **二级（仅在机制合法露出时生效）——角色显示名**：只用于 `/bearings` 状态报告、仪表盘，或船长**主动**问起内部机制时。绝不渗进日常的"结果式"汇报。

结论：主题化的第一价值是"人设与口吻"，其次才是极少数场景下的角色显示名。规范据此设计，而非天真地"把每个内部词都改名"。

## 4. 配置文件

- **位置**：`config/persona.md`（本地、gitignored）。与 `config/crew-harness`、`config/crew-dispatch.json` 等行为开关同处一室，符合第 1 节"个人化配置不进 git"的分层原则。
- **格式**：Markdown。因为这份文件只由我（LLM）读取并用于嗓音，**没有任何脚本解析它**，所以无需刚性 schema，人可直接手写手改。
- **默认（文件缺失）**：完全等同今天的行为——First Mate / captain / 轻航海腔（该默认口吻仍定义在 AGENTS.md 里）。缺失即默认，additive，零行为变化，与 X-mode "未开启即惰性" 同一套路。
- **示例包分发**：内置示例包作为**可入 git 的模板**放在 `docs/examples/persona-*.md`（与已有的 `docs/examples/crew-dispatch.json` 完全一致的模式）。用户把某个示例拷进本地 `config/persona.md` 即激活。

## 5. Voice pack 格式规范

```markdown
---
name: spongebob        # 包名，仅用于 bootstrap 提示
---

# 身份与口吻（一级，始终生效）
- 称呼船长为：蟹老板
- 我自称：凯伦
- 语气：干练、略带调侃的 AI 助手口吻；点缀词偶尔用比奇堡梗，
  但绝不淹没技术内容；报坏消息时收起玩味，只讲事实。

# 角色显示名（二级，仅状态报告/被问及内部机制时使用）
- crewmate   -> 海绵宝宝
- scout      -> 珊迪
- secondmate -> 分店经理
- 质量关(no-mistakes) -> 健康检查员

# 不覆盖项（保险声明，可省略——边界由第 6 节强制）
- 提交信息、PR、brief、给船员/工具看的内容一律用原始中性词。
```

字段说明：

- `name`：仅用于 bootstrap 的 `PERSONA:` 提示行。
- 一级三项（称呼/自称/语气）必填；缺任一则该项回落到默认口吻。
- 二级映射选填；未映射的角色在合法露出场景里用原始英文名。

## 6. 绝不主题化的边界（硬约束）

以下内容永远用原始中性词，与现有"航海点缀在任何船员/工具可读之处一律去掉"的规则同源：

- 提交信息、PR 标题与正文、brief、发给 crewmate/secondmate 的指令。
- 所有脚本、`state/*.meta`、`data/backlog.md`、任务 id、报告文件名。
- 任何被工具解析的 `data/`、`state/`、`config/` 文件内容。
- 报坏消息、转达严肃发现时，收起一切玩味点缀（沿用现有规则）。

## 7. 读取与生效

- **session start**：`bin/fm-session-start.sh` 的 digest 已经在读 `config/` 与 `data/captain.md`。新增：存在 `config/persona.md` 时，bootstrap 打印一行 `PERSONA: active config/persona.md (<name>)`（类比现有的 `CREW_HARNESS_OVERRIDE:` 与 `CREW_DISPATCH: active` 提示）；缺失则静默、用默认口吻。
- **生效方式**：我在会话开始读到该文件后，把一级身份/口吻应用到所有对船长的对话，把二级显示名仅应用到状态报告与"被主动问及机制"的场景。
- **校验**：极轻。除"是否存在"外无脚本解析，无需 JSON 式验证。

## 8. 待定决策：secondmate 是否继承

`config/crew-dispatch.json`、`config/crew-harness`、`config/backlog-backend` 都会被继承进 secondmate 家目录。persona 是否也继承有两种取法：

- **继承（推荐）**：整支船队对外一个口径，与其他 config 传播机制一致，可复用第 3 节的 `propagate_inheritable_config` 路径。
- **不继承**：每个家目录各自独立设人设。

倾向"继承"，但因它改变传播清单，需船长确认。

## 9. 落地改动清单（评审通过后再做，走正常流水线）

1. AGENTS.md 第 1 节身份块：把硬编码的"称呼 captain + 航海点缀"改写为"称呼/口吻/角色显示名取自激活的 persona pack；缺失时回落到此处定义的 First Mate 默认口吻"。
2. `bin/fm-session-start.sh` / bootstrap：新增 `PERSONA:` 提示行与继承传播（若决定继承）。
3. `config/*` 说明：在 AGENTS.md 第 2 节 layout 里登记 `config/persona.md`。
4. 新增示例包：`docs/examples/persona-spongebob.md`（及可选的一两个其他示例）。
5. 若继承：把 persona 加入 `propagate_inheritable_config` 的清单与文档描述。

以上属 firstmate 共享可跟踪材料的改动，须走分支→提交→no-mistakes 流水线→PR→船长合并，本文档仅为评审草稿。

## 10. 需船长拍板的点

1. 默认口吻保持"First Mate / captain / 航海腔"不变，对吗？（推荐：是，成本最低且是现有身份。）
2. secondmate 是否继承 persona？（推荐：继承。）
3. 除海绵宝宝外，是否还要内置其他示例包？
