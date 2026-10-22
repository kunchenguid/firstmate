-- bin/backends/rex-palette.lua - Firstmate's actions for Rex's command palette.
--
-- docs/rex-backend.md "Command palette" owns the public contract.
-- bin/fm-rex-palette.sh installs a guarded block into the local Rex server's
-- init.lua that loads this file with dofile and calls
-- setup{ root, home, path, server }. Every action asks
-- `bin/fm-rex-popup.sh plan <action>` what to do (that script's header owns
-- the plan and the popup bodies) and then does only that: open a floating
-- popup in the plan's session, and, when the action came from a key or the
-- palette, ask the app to show the plan's session. A plan's error is raised
-- so the palette shows it. No key is bound here: the captain assigns
-- shortcuts in the Rex app.

local M = {}

local TERMINAL = "com.superlogical.terminal.shell"
local BOUNDS = { 0.08, 0.08, 0.84, 0.8 }

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function plan(cfg, ctx, action, extra)
  local argv = { cfg.root .. "/bin/fm-rex-popup.sh", "plan", action }
  local function add(flag, value)
    if value ~= nil and value ~= "" then
      argv[#argv + 1] = flag
      argv[#argv + 1] = tostring(value)
    end
  end
  add("--session", ctx.session_id)
  add("--block", ctx.block_id)
  add("--server", ctx.server)
  for _, a in ipairs(extra or {}) do
    argv[#argv + 1] = a
  end
  local env = { PATH = cfg.path, FM_HOME = cfg.home }
  if cfg.server ~= nil and cfg.server ~= "" then
    env.FM_REX_SERVER = cfg.server
  end
  local r, err = rex.exec(argv, { env = env, timeout = 25 })
  if r == nil then
    error("Firstmate: " .. tostring(err), 0)
  end
  if not r.ok then
    local msg = trim(r.stderr)
    if msg == "" then msg = "the action failed" end
    error("Firstmate: " .. msg, 0)
  end
  local p, derr = rex.json.decode(r.stdout)
  if p == nil then
    error("Firstmate: unreadable plan: " .. tostring(derr), 0)
  end
  return p
end

-- Do what a plan says and return what was done as the action's result.
local function apply(ctx, p)
  local result = { action = p.action, task = p.task, message = p.message, away = p.away }
  if p.layer ~= nil then
    local res, err = rex.session.new_layer{
      session_id = p.layer.session_id,
      bounds = BOUNDS,
      focus = true,
      layout = rex.layout.block{
        flavor = TERMINAL,
        options = { command = p.layer.command, shell = "none" },
      },
    }
    if res == nil then
      error("Firstmate: could not open the popup: " .. tostring(err), 0)
    end
    result.layer_id = res.layer_id
  end
  if p.select ~= nil then
    result.select = p.select
    -- A queued client action fails a CLI or API caller that has no client, so
    -- only the captain's own key or palette use moves the view.
    if ctx.origin == "key" or ctx.origin == "palette" then
      rex.client.queue("session.select", p.select)
      result.selected = true
    end
  end
  return result
end

local ACTIONS = {
  {
    name = "fm_fleet", title = "Firstmate: Show Fleet", plan = "fleet",
    description = "Show every Firstmate worker, decision, and pull request in a popup.",
    keywords = "firstmate fleet workers status overview",
  },
  {
    name = "fm_this", title = "Firstmate: This Worker", plan = "this",
    description = "Show the focused worker's task, latest status, open decisions, and pull request.",
    keywords = "firstmate worker task status decision",
  },
  {
    name = "fm_peek", title = "Firstmate: Peek Worker", plan = "peek",
    description = "Follow the focused worker's screen in a popup, or its second mate's for a pane on another host.",
    keywords = "firstmate peek screen tail worker",
  },
  {
    name = "fm_goto", title = "Firstmate: Go to Waiting Worker", plan = "goto",
    description = "Show the tab of the worker waiting longest on you: a decision, then a blocker, a failure, a ready pull request.",
    keywords = "firstmate go jump worker waiting decision attention",
    args = { task = "string?" },
  },
  {
    name = "fm_away", title = "Firstmate: Show or Hide Away Pane", plan = "away",
    description = "Show the hidden away-mode supervisor pane beside your pane, or hide it again. It keeps running either way.",
    keywords = "firstmate away afk supervisor daemon pane show hide",
  },
  {
    name = "fm_answer", title = "Firstmate: Answer Decision", plan = "answer",
    description = "Answer an open decision; the answer goes to Firstmate's inbox, and Firstmate passes it on.",
    keywords = "firstmate answer decision reply question",
  },
  {
    name = "fm_note", title = "Firstmate: Tell Firstmate", plan = "note",
    description = "Send Firstmate a note, about the focused worker when there is one.",
    keywords = "firstmate tell note message steer",
  },
  {
    name = "fm_merge", title = "Firstmate: Request Merge", plan = "merge",
    description = "Ask Firstmate to merge a worker's pull request; Firstmate runs its usual checks first.",
    keywords = "firstmate merge pull request pr land",
  },
}

function M.setup(cfg)
  assert(type(cfg) == "table", "setup needs a table")
  for _, field in ipairs({ "root", "home", "path" }) do
    assert(type(cfg[field]) == "string" and cfg[field] ~= "", "setup needs " .. field)
  end
  for _, a in ipairs(ACTIONS) do
    rex.action{
      name = a.name,
      title = a.title,
      description = a.description,
      category = "Firstmate",
      keywords = a.keywords,
      args = a.args,
      run = function(ctx, args)
        local extra = {}
        if a.plan == "goto" and args.task ~= nil then
          extra = { "--task", tostring(args.task) }
        end
        return apply(ctx, plan(cfg, ctx, a.plan, extra))
      end,
    }
  end
end

return M
