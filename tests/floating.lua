-- Behavioral compositor model: dispatches update window geometry and workspace
-- membership, and workspace rules retain their enabled state like Hyprland's.
local engine, mode = assert(arg[1]), arg[2]
local windows, monitors, handlers, timers, rules
local checks = 0
local function check(message, condition)
  assert(condition, message)
  checks = checks + 1
  print("ok: " .. message)
end
local function rect(w) return { x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y } end
local function same(w, r)
  return math.abs(w.at.x - r.x) <= 1 and math.abs(w.at.y - r.y) <= 1 and w.size.x == r.w and w.size.y == r.h
end
local function reset(placement, stay)
  _G.__hyprpin = nil
  windows, handlers, timers, rules = {}, {}, {}, {}
  monitors = {
    { name = "DP-1", width = 1920, height = 1080, scale = 1, transform = 0,
      position = { x = 0, y = 0 }, reserved = { top = 30 }, active_workspace = { id = 1, name = "1" } },
    { name = "DP-2", width = 2560, height = 1440, scale = 1, transform = 0,
      position = { x = -2560, y = -200 }, reserved = { top = 40 }, active_workspace = { id = 4, name = "4" } },
  }
  local function get_window(selector)
    for _, w in ipairs(windows) do if selector == "address:" .. w.address then return w end end
  end
  local function get_monitor(name)
    for _, m in ipairs(monitors) do if m.name == name then return m end end
  end
  hl = {
    get_windows = function() return windows end, get_window = get_window, get_monitor = get_monitor,
    get_config = function(key)
      if key == "general:border_size" then return 2 end
      if key == "general:gaps_in" then return 5 end
      return 10
    end,
    on = function(event, callback)
      local sub = { callback = callback }
      function sub:remove() self.removed = true end
      handlers[event] = handlers[event] or {}
      table.insert(handlers[event], sub)
      return sub
    end,
    timer = function(callback, options) table.insert(timers, { callback = callback, options = options }) end,
    workspace_rule = function(options)
      local rule = { enabled = true, options = options }
      function rule:set_enabled(value) self.enabled = value end
      table.insert(rules, rule)
      return rule
    end,
    dsp = { window = setmetatable({}, { __index = function(_, method)
      return function(options) return { method = method, options = options } end
    end }) },
    dispatch = function(command)
      local op, options = command.method, command.options
      local w = assert(get_window(options.window), options.window)
      if op == "pin" then
        w.pinned = options.action == "on"
        w.workspace = w.monitor.active_workspace
      elseif op == "float" then w.floating = options.action == "on"
      elseif op == "resize" then w.size = { x = options.x, y = options.y }
      elseif op == "move" then
        if options.monitor then w.monitor = assert(get_monitor(options.monitor)) end
        if options.workspace then
          w.workspace = { id = tonumber(options.workspace) or -1, name = options.workspace,
            special = options.workspace:find("special:", 1, true) == 1 }
        end
        if options.x then w.at = { x = options.x, y = options.y } end
      elseif op == "fullscreen_state" then w.fullscreen = options.internal
      elseif op ~= "alter_zorder" then error("unhandled dispatch: " .. op) end
    end,
  }
  dofile(engine)
  __hyprpin.rules = { { class = "^Test$", title = "", monitor = "", placement = placement or "tile-right", stay = stay ~= false } }
end
local function emit(event, window)
  for _, sub in ipairs(handlers[event] or {}) do if not sub.removed then sub.callback(window) end end
end
local function tick(timeout)
  local pending = timers
  timers = {}
  for _, timer in ipairs(pending) do
    if timer.options.timeout == timeout then timer.callback() else table.insert(timers, timer) end
  end
end
local function workspace(id, monitor)
  local m = monitor or monitors[1]
  m.active_workspace = { id = id, name = tostring(id) }
  for _, w in ipairs(windows) do if w.pinned and w.monitor == m then w.workspace = m.active_workspace end end
  emit("workspace.active")
  tick(60)
end
local function new_window(address)
  local w = { address = address or "0x1", class = "Test", title = "", monitor = monitors[1],
    workspace = monitors[1].active_workspace, pinned = false, floating = false,
    fullscreen = 0, at = { x = 12, y = 42 }, size = { x = 1896, y = 1026 } }
  table.insert(windows, w)
  return w
end
local function pop()
  local w = new_window()
  check("manual pop handles a matching window", __hyprpin.toggle_pop(w.address))
  return w, __hyprpin.saved[w.address]
end
local function toggle(w) assert(__hyprpin.toggle_dock(w.address)) end
local function zoom(w) __hyprpin.toggle_big(w.address) end
local function position(w, x, y, width, height)
  w.at, w.size = { x = x, y = y }, { x = width, y = height }
end
local function custom(w) position(w, 480, 90, 960, 270) return rect(w) end
local key = "^Test$\31"

if mode == "reopen" then
  reset()
  local w, sv = pop()
  local edge = rect(w)
  toggle(w)
  check("new engine and new window restore persisted float", same(w, { x = 480, y = 90, w = 960, h = 270 }))
  toggle(w)
  check("new engine restores edge separately from float", same(w, edge) and not sv.detached)
  -- A monitor move and lower resolution keep the remembered spot on screen.
  monitors[1].width, monitors[1].height = 800, 600
  monitors[1].position = { x = -800, y = -100 }
  toggle(w)
  check("smaller display clamps width and uses its new origin",
    w.size.x == 800 and w.at.x == -800 and w.at.y >= -70 and w.at.y + w.size.y <= 500)
  return
elseif mode == "bounded" then
  reset()
  local w = pop()
  toggle(w)
  custom(w)
  toggle(w)
  return
end

for _, side in ipairs({ "left", "right", "top", "bottom" }) do
  reset("tile-" .. side, false)
  local w, sv = pop()
  local edge, reservation = rect(w), __hyprpin.edge_rule["DP-1"]
  toggle(w)
  check(side .. " detaches, stays pinned, and immediately releases tiles",
    w.pinned and w.floating and sv.detached and not reservation.enabled and not sv.edge_monitor)
  check(side .. " starts as a centered normal-sized float",
    w.size.x < 960 and math.abs(w.at.x - (1920 - w.size.x) / 2) <= 1)
  local wanted = custom(w)
  toggle(w) -- Capture without waiting for the sampler.
  check(side .. " reattaches with original geometry and home",
    same(w, edge) and not sv.detached and sv.workspace_id == 1 and __hyprpin.edge_rule["DP-1"].enabled)
  toggle(w)
  check(side .. " restores freely resized and moved float", same(w, wanted))
  workspace(2)
  workspace(1)
  check(side .. " stays detached across workspaces with Stay off", w.pinned and sv.detached and same(w, wanted))
  zoom(w)
  check(side .. " zoom remains half-width and 80% height", w.size.x == 960 and w.size.y == 840)
  toggle(w)
  check(side .. " T from floating zoom goes straight to original edge", same(w, edge) and not sv.big_prev)
  zoom(w)
  toggle(w)
  check(side .. " T from edge zoom restores the saved free float", same(w, wanted) and not sv.big_prev)
  zoom(w)
  tick(1500)
  zoom(w)
  check(side .. " zoom round trip and sampler preserve free placement", same(w, wanted))
  toggle(w)
  -- Resize the stripe and immediately detach: no sampler race and no overwrite of float.
  if side == "left" or side == "right" then w.size.x = 500 else w.size.y = 300 end
  toggle(w)
  check(side .. " resizing the edge does not overwrite float", same(w, wanted))
  toggle(w)
  check(side .. " edge remembers its own new thickness",
    (side == "left" or side == "right") and w.size.x == 500 or w.size.y == 300)
end

reset()
local w, sv = pop()
toggle(w)
custom(w)
tick(1500)
w.at.x = 200
tick(1500)
toggle(w)
toggle(w)
check("move-only sampler updates position without resize", w.at.x == 200)
local float = rect(w)
local other = new_window("0x2")
assert(__hyprpin.toggle_pop(other.address))
local occupied = __hyprpin.edge_rule["DP-1"]
toggle(w)
check("occupied edge leaves detached pin in its own float", same(w, float) and sv.detached and occupied.enabled)
emit("window.close", w)
check("closing detached pin cannot release another pin's edge", occupied.enabled and __hyprpin.saved[other.address])
emit("window.close", other)
check("closing the owner immediately releases its edge", not occupied.enabled)

reset()
w, sv = pop()
other = new_window("0x2")
assert(__hyprpin.toggle_pop(other.address))
local second = __hyprpin.saved[other.address]
check("second edge pin falls back to a float but keeps edge intent", second.detached and other.pinned)
emit("window.close", w)
toggle(other)
check("fallback pin can claim the edge once it is free", not second.detached and second.edge_monitor == "DP-1")

for _, stay in ipairs({ true, false }) do
  reset("bottom-right", stay)
  w, sv = pop()
  local wanted = custom(w)
  zoom(w)
  toggle(w)
  check("corner T while zoomed joins workspace layout", not w.pinned and not w.floating and sv.tiled and not sv.big_prev)
  zoom(w)
  toggle(w)
  check("docked zoom T returns to saved float", w.pinned and same(w, wanted) and not sv.dock and not sv.big_prev)
  toggle(w)
  zoom(w)
  workspace(2)
  check("leaving a zoomed dock returns to saved float", w.pinned and same(w, wanted) and not sv.big_prev)
  workspace(1)
  check("corner respects Stay on return", stay and w.pinned and same(w, wanted) or not stay and not w.pinned and not w.floating)
  if not stay then toggle(w) end
  wanted = custom(w)
  toggle(w)
  toggle(w)
  check("corner preserves immediate resize and movement", same(w, wanted) and w.pinned)
end

reset("bottom-right", false)
w, sv = pop()
w.monitor = monitors[2]
w.workspace = monitors[2].active_workspace
position(w, -2400, 100, 700, 300)
toggle(w)
check("docking on another display adopts that display and workspace", sv.monitor == "DP-2" and sv.workspace_id == 4)
workspace(5, monitors[2])
check("leaving the new home re-floats the pin", w.pinned and not sv.tiled)

reset("special")
w, sv = pop()
check("scratchpad remains unpinned and parked", w.workspace.special and not w.pinned)
toggle(w)
check("scratchpad can still dock into a workspace", sv.tiled and not w.workspace.special)
toggle(w)
check("scratchpad toggle returns to scratchpad", w.workspace.special and not sv.tiled)

reset("bottom-right")
w = pop()
custom(w)
tick(1500)
other = new_window("0x2")
assert(__hyprpin.toggle_pop(other.address))
position(other, 200, 300, 800, 400)
tick(1500)
local last_entry = __hyprpin.sizes[key]
tick(1500)
check("unchanged pins sharing a rule do not repeatedly overwrite its geometry", __hyprpin.sizes[key] == last_entry)

reset()
local ordinary = new_window()
ordinary.class = "Other"
check("ordinary windows retain stock keybind fallback", not __hyprpin.toggle_dock(ordinary.address))
w = new_window("0x2")
assert(__hyprpin.toggle_pop(w.address))
toggle(w)
custom(w)
__hyprpin.enabled = false
check("disabled plugin returns stock fallback", not __hyprpin.toggle_dock(w.address))

-- Finish with a real written state for the Node -> QML -> Lua reopen test.
reset()
w = pop()
toggle(w)
custom(w)
emit("window.close", w)
check("close persists a final drag before the next sampling tick", __hyprpin.sizes[key].floating.w == 960)
print("all " .. checks .. " floating transition checks passed")
