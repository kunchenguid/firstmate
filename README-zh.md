<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">跟一个一线代理对话，和一个船队一起交付。</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

[English README](README.md)

## 这是什么

firstmate 让你只和一个“第一副官（first mate）”沟通。你提出任务后，它会在底层自动分派“水手（crewmate）”并监督执行。

当你只需要做一件事时：一对一沟通足够。
当你需要同时处理多个任务时（修复、排查、计划、审计）：传统方式会变成不断切窗口、复制上下文和丢任务的“窗口杂耍”。

firstmate 的目标就是把这个复杂度收口：
- 自动创建可见的会话窗口（tmux/orca/herdr/zellij/cmux）
- 每个任务在独立 worktree 下运行
- 统一监督、自动回收、并在完成后给出可操作结果（PR、本地合并、审计报告）

firstmate 不是模型，不是 harness，不是 skill，不是 MCP，也不是单一 CLI。
它是一套**agent distro**：一套可复用的指令、技能、脚本和状态约定，给通用模型绑定到“船队协作”行为。

## 核心能力

- **单一入口**：你只与第一副官对话；它负责派单、监督、升级关键决策。
- **可见的船队**：每个 crewmate 在独立窗口/标签页中运行，可观察、可干预。
- **一次性 worktree**：每个任务拥有独立工作区，避免并行任务互相污染。
- **两类任务形态**：
  - ship：改动交付（产出代码与测试）
  - scout：调研/复现/计划/审计（产出 report）
- **可选 secondmate（副本副官）**：持久化域级监督者，使用独立 `FM_HOME` 与状态目录。
- **事件驱动、低 token 监督**：watcher 休眠，只有真正需要你关注时才唤醒。
- **可选 X mode**：通过本地 `.env` token 处理公开提及，支持可控的公开回复流程。
- **可恢复**：会话中断后可恢复，状态落盘并具备重连能力。

## 快速上手

### 先决条件

- 已认证的 Agent Harness：Claude Code / Grok / Pi / Codex / OpenCode
- Git 与 GitHub CLI（已 `gh auth login`）
- tmux（当前为参考后端）

first mate 会自动检测并在你同意后安装其余依赖。

### 安装与启动

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate
```

选择任一主推的 harness 启动：

**Claude Code**

```sh
claude
```

**Grok**

```sh
grok --trust
```

**Pi**

```sh
pi
```

### 与它交互

```sh
> ahoy! 查看我在 github 的 xyz 项目并修复 flaky login 用例，再补充 dark mode

# firstmate 负责：
# - 检查工具链（需要新安装会先征询）
# - 将项目纳入 projects/
# - 在后端启动两个 crewmate：fm-fix-login-k3、fm-dark-mode-p7
# - 任务完成后给你可复用产物（PR/本地结果）

  PR 已就绪，captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

## 工作原理

```text
你（Captain）
  |
  └── 向第一副官 firstmate 下发请求
      |
      ├── 启动任务窗口（tmux/herdr/zellij/cmux/Orca）
      ├── 任务运行在独立 worktree
      ├── 通过 watcher 监督状态
      └── 汇总为 PR / 本地合并 / 报告
```

firstmate 并不替代你，它负责执行和监督；你只处理关键决策与最终交付。

## 内置技能

Claude 与 Grok 使用斜杠指令；Codex 使用 `$` 前缀。

- `/afk`：进入离席模式，由副监督器低干预处理常规唤醒。
- `/bearings`：产出“从现场接续”的状态快照。
- `/updatefirstmate`：将 running firstmate 与 secondmate 快速对齐到最新。
- `/stow`：将未落盘的知识与结论沉淀到当前 FM_HOME。

详细说明：见 [AGENTS.md](AGENTS.md)。

### 两层技能组织

- `.agents/skills/`：firstmate 内部加载、仅本系统语义使用。
- `skills/`：对外可独立安装的公开 skill。

## 文档与贡献

- [docs/architecture.md](docs/architecture.md)
- [docs/configuration.md](docs/configuration.md)
- [docs/tmux-backend.md](docs/tmux-backend.md)
- [docs/herdr-backend.md](docs/herdr-backend.md)
- [docs/zellij-backend.md](docs/zellij-backend.md)
- [docs/orca-backend.md](docs/orca-backend.md)
- [docs/cmux-backend.md](docs/cmux-backend.md)
- [docs/codex-app-backend.md](docs/codex-app-backend.md)
- [docs/turnend-guard.md](docs/turnend-guard.md)
- [docs/supervision-protocols/](docs/supervision-protocols/)
- [docs/scripts.md](docs/scripts.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [LICENSE](LICENSE)

## 许可证

MIT（见 [LICENSE](LICENSE)）。
