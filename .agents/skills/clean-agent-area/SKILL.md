---
name: clean-agent-area
description: >-
  Use when the captain asks to clean the agent area, free space, or investigate low disk space, and during routine maintenance when the main home identifies cleanup work.
user-invocable: true
metadata:
  internal: true
---

# Clean agent area

## 铁律

- 先审后动；本 skill 只审计、分类并提出流程，不执行删除、移动、截断或其他破坏性修改。
- 不得删除未落地工作，也不得在引用关系未确认时删除任何对象。
- 每一步记录路径、命令、输出摘要与核验结果，保留可追溯证据。
- 任何破坏性动作都必须先取得船长对具体对象和动作的明确授权。
- 一次只清理足够解决当前空间需求的最小量，不批量扫荡。
- 不得使用 `--force` 或强制删除绕过守卫。

## 触发条件

- 船长要求清理、腾空间、处理磁盘快满，或清 agent 区域时加载本 skill。
- 例行维护中主家发现 agent 区域需要清理时也可主动加载。

## 只读审计

所有审计命令必须只读；不要运行会清理、修复、回收或改变文件的命令。

按下列三个根分别盘点，并为每项记录路径、占用、归属者和最近使用时间；可用 `du -sh`、`stat`、`find -print` 与 `ps` 收集证据，最近使用时间用文件系统可见的访问或修改时间并注明采用的字段。

```sh
# ① 本家：将 FM_HOME 解析为实际操作家目录后执行。
for root in "$FM_HOME/state" "$FM_HOME/data"; do
  [ -d "$root" ] && du -sh "$root" && find "$root" -mindepth 1 -maxdepth 3 -exec stat -f '%N | %z bytes | owner=%Su | mtime=%Sm | atime=%Sa' {} \;
done

# ② Harness 家目录：只检查存在的根目录，不递归读取文件内容。
for root in "$HOME/.pi/agent" "$HOME/.codex" "$HOME/.no-mistakes" "$HOME/.claude" "$HOME/.config/opencode"; do
  [ -d "$root" ] && du -sh "$root" && find "$root" -mindepth 1 -maxdepth 3 -exec stat -f '%N | %z bytes | owner=%Su | mtime=%Sm | atime=%Sa' {} \;
done

# ③ 隔离副本池：只读列出占用；不要运行 treehouse destroy、return、prune 或其他改变池状态的命令。
[ -d "$HOME/.treehouse" ] && du -sh "$HOME/.treehouse" && find "$HOME/.treehouse" -mindepth 1 -maxdepth 4 -exec stat -f '%N | %z bytes | owner=%Su | mtime=%Sm | atime=%Sa' {} \;
```

用任务记录和服务清单确认归属者及引用关系，不能仅凭旧时间或目录名称推断可删。

## 三态分类表

“可直接清理”仅表示审计分类上没有引用且可再生成，不授予删除权限；执行删除仍须船长对具体对象给字。

| 对象 | 分类 | 判定与检查步骤 | 建议动作 |
| --- | --- | --- | --- |
| `state/.watch-triage.log` | 条件清理 | 核对内容与任务记录，确认仅为 watcher 调试日志、尺寸受限，且没有其他证据或引用依赖该日志；任一项无法确认即不得列入候选。 | 核验后可列入最小候选，记录占用和用途。 |
| 已收工任务 `data/<id>/` 中 scratch 或临时件 | 条件清理 | 核验任务已收工；逐项确认对象仅为 scratch/临时件且无引用，保留 `report.md` 与调查证据；任一项不符即不得列入候选。 | 核验后逐项列入最小候选。 |
| `~/.pi/agent/models.json.bak-*` | 条件清理 | 核对引用关系并确认备份可再生成；保留最近一份，其余只有在无引用且可再生成时才列入候选。 | 逐项记录核验结果，仅列出通过项。 |
| 主家自己产的临时演示件 | 条件清理 | 核验所有权，确认由主家生成、仅供临时演示且无引用；任何条件无法确认即不得列入候选。 | 核验后可列入最小候选。 |
| `~/.pi/agent/sessions` | 条件清理 | 逐个确认不是当前会话，并且未被 `state/branch-session/`、未收工任务或未完成监督分支引用；任一引用存在或无法确认即禁止删该会话。 | 仅对通过全部检查的会话逐项申请授权。 |
| `~/.codex` | 条件清理 | 确认没有任何正在运行的 Codex 会话或任务；用当前进程与任务记录交叉核验，无法确认即禁止删。 | 等空闲后逐项申请授权。 |
| `state/*.status` 与 `state/*.meta` | 条件清理 | 只允许任务收工时由 `bin/fm-teardown.sh` 按其守卫删除；不得手动删除，尤其不得手删活任务记录，因为呈现游标按字节偏移引用它们，会破坏呈现与决策折叠。 | 任务收工交给 teardown；不得自行删文件。 |
| `data/<id>/` 整目录 | 条件清理 | 同时确认任务已收工且交付物已归档到其他位置；任一条件不成立即禁止整目录删除。 | 核对归档位置后逐任务申请授权。 |
| `~/.treehouse` 脏槽 | 条件清理 | 必须同时确认无活 pane 占用、未落地内容已抢救并逐字节核验、且船长已具体授权；不得动 in-use 或 leased 槽，也不得动别人的兄弟槽。仅在上述条件成立后，先用 `treehouse destroy <path> --include-unlanded` dry-run 检视，再由获授权者确认后加 `--yes`；没有授权不得运行破坏动作。 | 不批量；把单一槽的 dry-run 证据与核验结果交船长。 |
| `~/.no-mistakes` | 条件清理 | 只有 daemon 空闲且无活跃 run 时才可评估；该 daemon 归主家管理，其他人不得绕过或直接处置。 | 转交主家确认和执行。 |
| `state/pending-replies/expired/` | 条件清理 | 确认每条记录对应任务均已收工；有活任务或无法对应即不得删。 | 仅列出已收工关联项供授权。 |
| `state/<id>.inbox/handled/` | 条件清理 | 确认对应任务已收工；活任务或归属不明时不得删。 | 仅列出已收工关联项供授权。 |
| watcher 内部件：`.hash-*`、`.count-*`、`.stale-*`、`.stale-since-*`、`.churn-since-*`、`.paused-*`、`.wedge-escalations-*`、`.writing-*`、`.waiting-*`、`.seen-*`、`.hb-surfaced-*`、`.last-*`、`.heartbeat-streak`、`.watch.lock`、`.wake-queue*`、`.watcher-down`、`.last-watcher-beat`、`.startup-network.*` | 禁止清理 | 这些均为 watcher 或启动监督内部状态。 | 不得列入候选。 |
| `state/.branch-outcomes*` 及其游标 | 禁止清理 | 是持久监督结果及读取位置。 | 不得列入候选。 |
| `state/.status-presentation-cursor` 与 `state/.*-open-decisions-cursor` | 禁止清理 | 游标维护状态呈现与决策折叠。 | 不得列入候选。 |
| `state/.afk-contract` 与 `state/.afk` | 禁止清理 | 持久的 away/quiet 委托记录。 | 不得列入候选。 |
| treehouse leased 或 in-use 槽 | 禁止清理 | 由工作或租约占用；不得回收、返回或移动。 | 不得列入候选。 |
| 任何未收工任务的 `state/` 与 `data/` 记录 | 禁止清理 | 活任务记录可能包含工作、交付物、决策或引用。 | 不得列入候选。 |
| `data/captain.md`、`data/captain-shared.md`、`data/learnings.md`、`data/secondmates.md`、`data/projects.md`、`data/backlog.md` | 禁止清理 | 属于持久偏好、知识、登记或队列记录。 | 不得列入候选。 |

权威机制以 `bin/fm-teardown.sh` 和 `docs/configuration.md` 为准；本表不替代它们的守卫。

## 流程

1. 只读审计三个根目录，记录每个候选的路径、占用、归属、最近使用时间和证据来源。
2. 按三态分类表判断；条件清理必须逐条记录条件核验，条件不成立或证据不足即标记禁止清理。
3. 向船长提供候选表，列为“路径 / 占用 / 归属 / 分类 / 删除条件 / 建议动作”，并明确哪些动作仍需船长给字。
4. 等待船长对具体路径和动作授权；没有给字只停留在审计与建议，不执行删除。
5. 获授权后先抢救或备份相关内容，并逐字节核验副本；核验失败即停止，不删除源内容。
6. 只处理已批准且足以满足当前需求的最小量，不扩展到相邻对象或批量清理。
7. 清理者核验处理前后字节数及相关服务、进程仍存活，并确认目标状态符合批准范围。
8. 记录结果、释放空间证据、未处理项及可用回滚方式；无法证明实际释放空间时不得声称已释放容量。

## 反例

- 把脏隔离副本池当垃圾批量清理，会毁掉其他工作者尚未落地的工作。
- 把未收工任务目录当作整理习惯清掉，会丢失任务记录、证据或交付物。
- 使用强制删除绕过守卫，会让正在使用的数据或服务失去保护。
- 不核验前后占用就声称已释放若干 GB，会把估算冒充实际结果。
