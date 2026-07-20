# fm-arm-churn-fix 调查中间态（WIP，最终 MR 前删除本目录）

状态：船长 2026-07-21 指令停手，调查做到一半固化于此。
尚未改任何 tracked 代码；本目录是唯一改动。
接手前先读完本文件，尤其"未解矛盾"和"下一步"两节。

## 任务回顾

修掉"武装空转"：轮末守卫（Stop hook）拦下未武装的轮 → 再花一整轮只为武装。
两周实测 240 个 guard 强制轮（$133），watch-arm 1320 次 vs 真实 wake 908 次。
硬约束：守卫保留、不许放宽；监督覆盖只能更强；不许第二条监督循环。

## 已确认的一手证据（全部来自 ~/.claude/projects/-Users-bytedance-orca-firstmate/*.jsonl，36 个会话）

用本目录的 4 个 python 脚本重跑即可复现（脚本无参数，直接 python3 跑）：

- analyze_guard.py：按(种类, 触发源)分类全部 guard fire。
- analyze_gap.py：测"武装动作 → guard fire"的时间差。
- analyze_timeline.py：guard fire 之后多久来 task-notification。
- analyze_taskid.py：把轮内 arm 的 task-id 对到它自己的 notification。

### 关键数字

1. guard fire 共 231 次；fm-watch-arm 工具调用共 1334 次；wake-notification 轮共 935 个，其中 809 个轮内武装过（bg）。
2. **231 次里 152 次（66%）发生在"本轮已经用 run_in_background 发过 fm-watch-arm"的轮上**（blocked-despite-bg-arm）。
   只有 79 次是真没武装（45 次 wake 轮、32 次船长轮、2 次 skill 轮）。
   → 主要空转不是"模型忘了武装"，是"武装了仍被拦"。
3. arm 发出 → guard fire 的间隔：min 3.5s / 中位 6.0s / 分布 {2-5s: 47, 5-15s: 79, 15-60s: 23, ≥60s: 3}。
4. guard fire 时 beacon 年龄：中位 8s；179/231 <60s；仅 7 次 ≥300s。
   → guard 几乎总是在"watcher 刚退出/刚启动"的瞬间开火，不是长时间失监督。
5. 152 次 blocked-despite-bg-arm 里，121 次在 fire 后 ≤90s（中位 11s）就有 task-notification 送达——模型反正马上会被唤醒，guard 强制轮是重复劳动。
6. 轮内最后那次 arm 的 task-id，151/152 在整个 transcript 里从未出现完成通知（task-never-notified）——它启动的 watcher 活着停驻（正常），guard 却说没有活 watcher。
7. guard 强制续轮 210/231 次确实重新武装了；每次续轮中位 2 个 assistant 请求——每次 fire 实打实多花一轮。

### 深挖个案（session 066dc8cb，fire=2026-07-14T16:21:06.948Z）

- 16:20:12 模型发 arm#1（task bfn1mwvsl）。
- 16:20:46 arm#1 完成通知**在轮中**送达（watcher#1 因 signal+30s SIGNAL_GRACE 开火退出）。
- 16:21:00.580 模型发 arm#2（task bas34s589），tool_result 16:21:01.619。
- 16:21:06.948 guard 开火："no live watcher holds this home lock (last beat: 5s ago)"。
- 强制续轮 16:21:44 读 arm#2 输出：**"watcher: started pid=32186 (beacon fresh)" + 随后又一条 stale wake**。
- beacon 5s 前被摸过（≈16:21:01.9），只能是 watcher#2 的首拍（watcher#1 最后一拍在 ≈16:20:13，年龄应为 53s）。

## 未解矛盾（root cause 还差最后一步，勿跳过直接写修复）

fm-watch.sh 主入口顺序是：拿锁 → 写 fm-home/watcher-path/pid-identity → 循环首拍 beacon。
即 beacon 首拍时锁文件已齐。
个案里 fire 时 beacon 5s 新（watcher#2 已拍过），watcher#2 进程活着（它的 task 直到 16:21:30+ 才因下一条 stale 退出），可 guard 的 fm_watcher_healthy（bin/fm-wake-lib.sh）仍返回失败。
三个可疑组件：fm_pid_alive(lock pid)、fm_watcher_lock_matches_pid（fm-home / watcher-path / pid-identity 三比对）、beacon 年龄（已排除）。
可能方向：hook 进程环境下 WATCH 路径解析与 arm 侧不一致（CLAUDE_PROJECT_DIR vs cwd 的 symlink/logical-path 差异）、`ps` 高负载下 lstart 秒级抖动导致 identity 比对失败、或锁 symlink 中间态。
**必须用活体复现钉死是哪个组件失败**，然后才知道修 guard 侧还是修 watcher/arm 侧。

## 下一步（按序）

1. 活体复现实验：沙箱 FM_HOME（用 FM_ROOT_OVERRIDE/FM_STATE_OVERRIDE 指到 scratch，放一个假 *.meta），
   启动 bin/fm-watch-arm.sh，另开 50ms 轮询逐组件记录 fm_pid_alive / lock_matches(逐文件) / beacon 各自何时通过；
   同时按 fm-turnend-guard.sh 的调用方式（echo payload | 管道、CLAUDE_PROJECT_DIR 形态的路径）跑守卫本体，看它何时从 2 变 0。
   重点比对：与个案相同的"胖路径 vs 逻辑路径"（~/orca/firstmate 那台机器的路径形态）。
2. 钉死组件后定修法。当前倾向（未定论）：
   a) guard 对"武装进行中/交接进行中"的窄容忍：本 home 存在活的 arm/watcher 进程且 beacon 秒级新时，有界等待（≤2-3s）复查一次再决定拦不拦——不加开关、不放宽"没人在武装"时的拦截，保险丝不变弱。
   b) 若是路径/identity 比对 bug，直接修比对（这可能就是 152 次的全部根因，修完 guard 误拦自然消失）。
   c) 79 次真没武装的轮（尤其 45 次 wake 轮）是第二类，量小；等 a/b 落地后看剩余量再决定是否单独处理。
3. 回归测试两条腿（tests/fm-turnend-guard.test.sh 扩展，勿新造 runner）：
   - "该武装的时候武装上了 / 武装中不误拦"：armed watcher 健康或武装交接进行中时 guard 放行；
   - "保险丝仍在"：无 watcher、无武装动作时 guard 必须 exit 2 拦下（现有用例已覆盖大半，别删）。
4. 记得：Claude 上 Stop hook 进程**造不出 harness-tracked 背景任务**——hook 自己 fork watcher 的话，watcher 退出没人唤醒模型（wake 落队列但无通知渠道），监督反而变弱。
   所以任务描述里的"方向 2（守卫直接自动武装）"在 claude 上朴素做法不成立；除非能证明有等效唤醒渠道，否则走"让武装可靠 + 守卫消除误拦"。
5. 写 MR 时（direct-PR，中文描述）：说明真实成因 + 证据（上面数字）、修法理由、两条回归测试；
   声明 CI 的 Behavior tests 在 main 上就红（fm-backend.test.sh old-bin 夹具，另有 fm-oldbin-fixture-fix-w9 在修）；
   不碰 bin/fm-spawn.sh（fm-spawn-isolation-assert-hole-v4 在改）；
   若改动触及唤醒载荷协议，MR 里点明给后续 fm-wake-payload-prefetch 接。
6. 交付前删除本目录（.task-notes/）。

## 约束提醒

- 改 tracked 文件前已加载 firstmate-coding-guidelines：一行一句、shellcheck、bin/fm-lint.sh、测试与现有 runner 同构、commit 不加 agent co-author。
- 守卫的谱系文档在 docs/turnend-guard.md（含五 harness 验证记录）；改共享谓词要按其"Compatibility and enforcement"检查所有 harness 面。
