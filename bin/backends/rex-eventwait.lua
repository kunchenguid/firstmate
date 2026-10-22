-- bin/backends/rex-eventwait.lua - the Rex adapter's bounded event reader.
--
-- Run by fm_backend_rex_event_reader (bin/backends/rex.sh) as
--   rex --autostart=false do -s <session-id> --for <N>s rex-eventwait.lua \
--     --args '{"blocks":["block:<uuid>", ...]}'
-- It streams one TAB-separated line per event on a watched block and leaves
-- every policy decision to the bash caller:
--   <block-id>\t<state>\t<kind>\t<app>\t<owner-pid>\t<msg>   program_status_changed
--   <block-id>\tgone\t\t\t\t<why>                          child_exited, block_closed
-- "@subscribed" is printed once the handlers are listening, so the caller's
-- level reconcile runs only after edges are already being delivered. The
-- script never stops itself: `rex do` exits 0 at the --for deadline (or when
-- the session is destroyed), and the caller kills it once it has its answer.

local watched = {}
for _, id in ipairs((rex.args or {}).blocks or {}) do
  watched[id] = true
end

local function clean(value)
  if value == nil then
    return ""
  end
  return (tostring(value):gsub("[\t\r\n]", " "))
end

local function emit(block, state, kind, app, owner, msg)
  print(table.concat({ clean(block), clean(state), clean(kind), clean(app), clean(owner), clean(msg) }, "\t"))
  io.stdout:flush()
end

rex.on("terminal.program_status_changed", function(ctx, ev)
  if not watched[ctx.block_id] then
    return
  end
  local record = ev.record or {}
  local owner = record.owner or {}
  emit(ctx.block_id, record.state, record.kind, record.app, owner.pid, record.msg)
end)

rex.on("terminal.child_exited", function(ctx)
  if watched[ctx.block_id] then
    emit(ctx.block_id, "gone", "", "", "", "program exited")
  end
end)

rex.on("block_closed", function(_, ev)
  if watched[ev.block_id] then
    emit(ev.block_id, "gone", "", "", "", "block closed")
  end
end)

rex.after(0, function()
  print("@subscribed")
  io.stdout:flush()
end)
