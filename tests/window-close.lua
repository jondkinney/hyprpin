-- Close events arrive before Hyprland removes the window from get_windows().
-- The handler must use that event's identity, not a delayed missing-window scan.
local engine = assert(arg[1])
local handlers, timers, windows, updates
local checks = 0

local function check(message, condition)
  assert(condition, message)
  checks = checks + 1
  print("ok: " .. message)
end

local function reset()
  _G.__hyprpin = nil
  handlers, timers, windows, updates = {}, {}, {}, {}
  hl = {
    on = function(event, callback)
      local subscription = { callback = callback }
      function subscription:remove() self.removed = true end
      handlers[event] = handlers[event] or {}
      table.insert(handlers[event], subscription)
      return subscription
    end,
    timer = function(callback, options)
      table.insert(timers, { callback = callback, options = options })
    end,
    get_windows = function() return windows end,
    get_window = function(selector)
      for _, window in ipairs(windows) do
        if selector == "address:" .. window.address then return window end
      end
    end,
  }
  dofile(engine)
end

local function emit(event, window)
  for _, subscription in ipairs(handlers[event] or {}) do
    if not subscription.removed then subscription.callback(window) end
  end
end

local function track(address, monitor, side)
  local window = { address = address, pinned = true }
  table.insert(windows, window)
  __hyprpin.saved[address] = { edge = side, edge_monitor = monitor }
  if monitor then
    local rule = { enabled = true }
    function rule:set_enabled(enabled)
      self.enabled = enabled
      table.insert(updates, { monitor = monitor, enabled = enabled })
    end
    __hyprpin.edge_rule[monitor] = rule
    return window, rule
  end
  return window
end

for _, side in ipairs({ "left", "right", "top", "bottom" }) do
  reset()
  local window, rule = track("0x1", "DP-1", side)
  local neighbor, otherRule = track("0x2", "DP-2", "right")
  local timerCount = #timers
  emit("window.close", window)
  check(side .. " edge releases during close, while window remains mapped",
    #windows == 2 and not rule.enabled and __hyprpin.saved[window.address] == nil
      and __hyprpin.edge_rule["DP-1"] == nil)
  check(side .. " close needs no workspace switch or timer",
    #timers == timerCount and #updates == 1 and updates[1].enabled == false)
  check(side .. " close preserves the other display's reservation",
    otherRule.enabled and __hyprpin.saved[neighbor.address] ~= nil)
  emit("window.close", window)
  check(side .. " duplicate close is harmless", #updates == 1)
end

reset()
local corner = track("0x3")
local edge, rule = track("0x4", "DP-1", "left")
emit("window.close", corner)
check("closing a corner pin leaves tiled space alone",
  __hyprpin.saved[corner.address] == nil and rule.enabled and #updates == 0)
emit("window.close", { address = "0x99" })
emit("window.close", nil)
emit("window.close", {})
check("untracked or expired close events leave tracked windows alone",
  __hyprpin.saved[edge.address] ~= nil and rule.enabled and #updates == 0)

-- Configuration reapplication preserves tracked windows and replaces listeners.
reset()
local kept, keptRule = track("0x5", "DP-1", "right")
local oldClose = handlers["window.close"] and handlers["window.close"][1]
for _ = 1, 3 do dofile(engine) end
for _, event in ipairs({ "workspace.active", "window.close" }) do
  local count = 0
  for _, subscription in ipairs(handlers[event] or {}) do
    if not subscription.removed then count = count + 1 end
  end
  check("reapplying keeps exactly one " .. event .. " listener", count == 1)
end
check("reapplying preserves an active reservation",
  keptRule.enabled and __hyprpin.saved[kept.address] ~= nil)
oldClose.callback(kept)
check("a callback retained from the old generation cannot release current state",
  keptRule.enabled and __hyprpin.saved[kept.address] ~= nil)
emit("window.close", kept)
check("the new listener still releases the preserved reservation", not keptRule.enabled)

-- Cleanup must not depend on the global matching toggle.
reset()
local stopped, stoppedRule = track("0x6", "DP-1", "bottom")
__hyprpin.enabled = false
emit("window.close", stopped)
check("close cleanup is independent of the matching toggle",
  not stoppedRule.enabled and __hyprpin.saved[stopped.address] == nil)

print(string.format("all %d window-close checks passed", checks))
