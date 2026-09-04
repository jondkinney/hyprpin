import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Turns the rules written by the bar widget into a live Hyprland behaviour.
//
// Wayland gives an application no way to place, size or pin its own window, so
// "keep this call visible when I switch workspace" can only come from the
// compositor. The mechanism is Hyprland's `pin`, which does more than mark a
// window: pinning one that lives on a hidden workspace pulls it onto the
// visible one. Unpinning is the mirror image and drops it wherever you happen
// to be, which is why the engine below sends a window home by name instead.
// Rules can opt into tiling instead, where the window joins the layout in its
// corner and is carried from workspace to workspace by hand.
//
// The engine runs inside Hyprland's own Lua state rather than here, for two
// reasons: it needs the workspace.active event with no IPC round trip, and it
// keeps working if the shell restarts. This service only ever generates that
// Lua and pushes it in, the same way the bazecor-lens plugin applies its rules.
Item {
    id: root

    // Injected by the shell's service loader (see shell.qml ensureService).
    property var shell: null

    readonly property string pluginId: "io.github.jondkinney.hyprpin"
    readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/hyprpin.json"
    // Remembered pop-out sizes, written and read by the engine itself so they
    // survive both shell restarts and Hyprland config reloads.
    readonly property string sizesPath: Quickshell.env("HOME") + "/.local/state/omarchy/hyprpin-sizes.lua"

    // Our shell.json entry holds the tuning knobs. A plugin that declares a bar
    // widget is enabled from bar.layout rather than plugins[], so look in both
    // and keep working whichever way it was set up.
    readonly property var settings: {
        var cfg = shell && shell.shellConfig ? shell.shellConfig : null
        if (!cfg)
            return ({})
        var pools = [cfg.plugins]
        if (cfg.bar && cfg.bar.layout)
            pools.push(cfg.bar.layout.left, cfg.bar.layout.center, cfg.bar.layout.right)
        for (var p = 0; p < pools.length; p++) {
            var list = pools[p]
            if (!list)
                continue
            for (var i = 0; i < list.length; i++) {
                var entry = list[i]
                if (entry && typeof entry.id === "string"
                        && entry.id.length <= 128 && entry.id === pluginId)
                    return entry
            }
        }
        return ({})
    }

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined
        return value === undefined || value === null ? fallback : value
    }

    function clampInt(value, low, high, fallback) {
        var n = Math.round(Number(value))
        return isFinite(n) && n >= low && n <= high ? n : fallback
    }

    readonly property int cornerWidthPercent: clampInt(setting("cornerWidthPercent", 22), 5, 100, 22)
    readonly property int cornerMinWidth: clampInt(setting("cornerMinWidth", 420), 100, 8000, 420)
    readonly property int margin: clampInt(setting("margin", 20), 0, 500, 20)

    readonly property var placements: ["bottom-right", "bottom-left", "top-right", "top-left"]
    readonly property string fallbackPlacement: {
        var value = setting("fallbackPlacement", "bottom-right")
        return placements.indexOf(value) >= 0 ? value : "bottom-right"
    }

    // ------------------------------------------------------------------ rules

    property var rules: []

    // Everything here comes off disk and is editable by hand, so it is treated
    // as untrusted: shapes are checked, strings are bounded, and the monitor
    // name and placement are whitelisted rather than sanitised.
    function parseRules(raw) {
        if (typeof raw !== "string" || raw.length === 0 || raw.length > 262144)
            return []
        var parsed
        try {
            parsed = JSON.parse(raw)
        } catch (e) {
            console.warn("hyprpin: rules file is not valid JSON, ignoring it")
            return []
        }
        if (!parsed || !Array.isArray(parsed.rules))
            return []

        var out = []
        for (var i = 0; i < parsed.rules.length && out.length < 64; i++) {
            var r = parsed.rules[i]
            if (!r || typeof r !== "object")
                continue
            var cls = typeof r["class"] === "string" ? r["class"] : ""
            var title = typeof r.title === "string" ? r.title : ""
            if (!cls.length || cls.length > 256 || title.length > 256)
                continue
            var monitor = typeof r.monitor === "string" ? r.monitor : ""
            if (monitor.length && !/^[A-Za-z0-9._:-]{1,64}$/.test(monitor))
                continue
            var placement = typeof r.placement === "string" ? r.placement : "fill"
            if (placement !== "fill" && placements.indexOf(placement) < 0)
                continue
            out.push({
                "class": cls, title: title, monitor: monitor, placement: placement,
                stay: r.stay === true, tile: r.tile === true
            })
        }
        return out
    }

    FileView {
        id: rulesFile
        path: root.statePath
        watchChanges: true
        printErrors: false
        onLoaded: { root.rules = root.parseRules(text()); root.applySoon() }
        onFileChanged: reload()
        // First run: no file yet. Still apply, so a config reload does not leave
        // a previously popped window stranded with no engine to restore it.
        onLoadFailed: { root.rules = []; root.applySoon() }
    }

    // ------------------------------------------------------------- Lua output

    function luaString(value) {
        var s = typeof value === "string" ? value : ""
        if (s.length > 256)
            s = s.slice(0, 256)
        var out = ""
        for (var i = 0; i < s.length; i++) {
            var ch = s.charAt(i)
            var code = s.charCodeAt(i)
            if (ch === "\\")
                out += "\\\\"
            else if (ch === '"')
                out += '\\"'
            else if (code < 32 || code === 127)
                // Zero-padded so a following digit cannot extend the escape.
                out += "\\" + ("00" + code).slice(-3)
            else
                // Non-ASCII passes through untouched: the chunk reaches
                // hyprctl as UTF-8 argv bytes and Lua strings are byte
                // strings, so patterns and window text compare bytewise. A
                // Lua decimal escape only holds values up to 255, so escaping
                // a code point here corrupted it -- U+25D1 emitted "\681",
                // which does not even load.
                out += ch
        }
        return '"' + out + '"'
    }

    function rulesLua() {
        var parts = []
        for (var i = 0; i < rules.length; i++) {
            var r = rules[i]
            parts.push("  { class = " + luaString(r["class"])
                + ", title = " + (r.title.length ? luaString(r.title) : "nil")
                + ", monitor = " + luaString(r.monitor)
                + ", placement = " + luaString(r.placement)
                + ", stay = " + (r.stay ? "true" : "false")
                + ", tile = " + (r.tile ? "true" : "false") + " },")
        }
        return parts.join("\n")
    }

    function lua() {
        return [
// Leading empty line on purpose: hyprctl parses an argument beginning with
// "--" as one of its own flags and prints its usage instead of evaluating,
// so the chunk must not open on a Lua comment.
'',
'-- managed by io.github.jondkinney.hyprpin -- edits here are overwritten',
'local S = _G.__hyprpin or {}',
'_G.__hyprpin = S',
'',
'-- Re-applying must never stack a second handler on the event, and the',
'-- generation counter retires any sampler chain from a previous apply.',
'if S.sub then pcall(function() S.sub:remove() end) S.sub = nil end',
'S.gen = (S.gen or 0) + 1',
'local gen = S.gen',
'-- Whatever is popped out right now stays tracked across a re-apply, so',
'-- changing a setting mid-call cannot strand a window.',
'S.saved = S.saved or {}',
'',
'S.rules = {',
rulesLua(),
'}',
'S.width_fraction = ' + (cornerWidthPercent / 100),
'S.min_width = ' + cornerMinWidth,
'S.margin = ' + margin,
'S.aspect = 16 / 9',
'S.fallback = ' + luaString(fallbackPlacement),
'S.sizes_path = ' + luaString(sizesPath),
'',
'-- Sizes the user gave pop-outs by hand, keyed per rule. The file is a Lua',
'-- chunk this engine writes itself, so it survives config reloads.',
'do',
'  local ok, loaded = pcall(dofile, S.sizes_path)',
'  if ok and type(loaded) == "table" then',
'    local clean = {}',
'    for k, v in pairs(loaded) do',
'      if type(k) == "string" and type(v) == "table" and tonumber(v.w) and tonumber(v.h) then',
'        clean[k] = { w = math.floor(tonumber(v.w)), h = math.floor(tonumber(v.h)) }',
'      end',
'    end',
'    S.sizes = clean',
'  else',
'    S.sizes = S.sizes or {}',
'  end',
'end',
'',
'local function persist_sizes()',
'  local f = io.open(S.sizes_path, "w")',
'  if not f then return end',
'  f:write("-- written by hyprpin: pop-out sizes remembered from hand resizes.\\n")',
'  f:write("-- delete this file (or one entry) to forget.\\n")',
'  f:write("return {\\n")',
'  for k, v in pairs(S.sizes) do',
'    f:write(string.format("  [%q] = { w = %d, h = %d },\\n", k, v.w, v.h))',
'  end',
'  f:write("}\\n")',
'  f:close()',
'end',
'',
'local function rule_key(rule)',
'  return rule.class .. "\\031" .. (rule.title or "")',
'end',
'',
'local function remembered(rule)',
'  local sz = rule and S.sizes[rule_key(rule)] or nil',
'  if sz and sz.w and sz.w >= 100 and sz.h and sz.h >= 60 then return sz end',
'  return nil',
'end',
'',
'-- A hand-edited rules file can hold a malformed Lua pattern; one bad rule',
'-- must not take every pop and restore down with it.',
'local function matches(value, pattern)',
'  local ok, found = pcall(string.match, value, pattern)',
'  return ok and found ~= nil',
'end',
'',
'local function eligible(window)',
'  local class, title = window.class or "", window.title or ""',
'  for _, rule in ipairs(S.rules) do',
'    if matches(class, rule.class) and (not rule.title or matches(title, rule.title)) then',
'      return rule',
'    end',
'  end',
'  return nil',
'end',
'',
'-- Monitor sizes are reported in physical pixels while window and workspace',
'-- geometry is logical, so every dimension here is divided by the scale.',
'local function usable(monitor)',
'  local width = monitor.width / monitor.scale',
'  local height = monitor.height / monitor.scale',
'  if monitor.transform % 2 == 1 then width, height = height, width end',
'  local r = monitor.reserved or {}',
'  local left, top = (r.left or 0), (r.top or 0)',
'  return math.floor(width - left - (r.right or 0)),',
'    math.floor(height - top - (r.bottom or 0)),',
'    math.floor(monitor.position.x + left + 0.5),',
'    math.floor(monitor.position.y + top + 0.5)',
'end',
'',
'local function geometry(monitor, placement, override)',
'  local uw, uh, ux, uy = usable(monitor)',
'  if placement == "fill" then',
'    return uw, uh, ux, uy',
'  end',
'  local w = math.max(math.floor(uw * S.width_fraction + 0.5), S.min_width)',
'  local h = math.floor(w / S.aspect + 0.5)',
'  if override then',
'    w = math.min(override.w, uw)',
'    h = math.min(override.h, uh)',
'  end',
'  local x = placement:find("left") and (ux + S.margin) or (ux + uw - w - S.margin)',
'  local y = placement:find("top") and (uy + S.margin) or (uy + uh - h - S.margin)',
'  return w, h, math.floor(x + 0.5), math.floor(y + 0.5)',
'end',
'',
'-- Push a tiled window into its corner of the layout, then nudge the splits',
'-- toward the wanted size. Exact resize on tiled windows anchors on the',
'-- split\'s first pane (verified: addressing the right pane resized the left',
'-- one), so far-side axes request the complement instead. Approximate by',
'-- nature -- the layout has the last word.',
'-- Settle a freshly-tiled window into the layout. Forcing it into a named',
'-- corner meant walking it with directional moves, which near a monitor edge',
'-- escaped onto the abutting display -- so tiled placement is left to the',
'-- layout (as its size already was). Kept as a hook in case a safe corner',
'-- nudge is added later.',
'local function place_tiled(address, monitor, placement, tw, th)',
'end',
'',
'-- Float the window to its configured corner/display and pin it. Split out so',
'-- the manual pop (SUPER+O), the dock toggle and the auto-pop all share it.',
'local function place_float(window, sv, rule)',
'  local selector = "address:" .. window.address',
'  local place_on = sv.placed_on and hl.get_monitor(sv.placed_on) or window.monitor',
'  if not place_on then return end',
'  local placement = sv.placed_at or S.fallback',
'  if (window.fullscreen or 0) ~= 0 then',
'    hl.dispatch(hl.dsp.window.fullscreen_state({ window = selector, internal = 0, client = 0 }))',
'  end',
'  if place_on.name ~= (window.monitor and window.monitor.name) then',
'    hl.dispatch(hl.dsp.window.move({ window = selector, monitor = place_on.name, follow = false }))',
'  end',
'  local w, h, x, y = geometry(place_on, placement, remembered(rule))',
'  hl.dispatch(hl.dsp.window.float({ window = selector, action = "on" }))',
'  hl.dispatch(hl.dsp.window.resize({ window = selector, x = w, y = h, exact = true }))',
'  hl.dispatch(hl.dsp.window.move({ window = selector, x = x, y = y, exact = true }))',
'  hl.dispatch(hl.dsp.window.pin({ window = selector, action = "on" }))',
'  hl.dispatch(hl.dsp.window.alter_zorder({ window = selector, mode = "top" }))',
'  sv.expected_w, sv.expected_h = w, h',
'  sv.tiled = false',
'end',
'',
'local function pop_float(window, rule)',
'  local home_monitor, home_workspace = window.monitor, window.workspace',
'  if not home_monitor or not home_workspace then return end',
'',
'  local selector = "address:" .. window.address',
'  local placement = rule.placement',
'  local target = nil',
'',
'  if rule.monitor ~= "" then',
'    target = hl.get_monitor(rule.monitor)',
'    -- Named display gone: another machine profile, or simply unplugged.',
'    if not target then placement = S.fallback end',
'    if target and target.name == home_monitor.name then target = nil end',
'  end',
'  -- Filling the display the window is already on would just bury the',
'  -- workspace behind it, so a corner is the only sensible reading.',
'  if not target and placement == "fill" then placement = S.fallback end',
'',
'  -- Two windows filling the same display would just stack there, with the',
'  -- one behind invisible -- a later arrival takes its fallback corner instead.',
'  if target and placement == "fill" then',
'    for other, entry in pairs(S.saved) do',
'      if other ~= window.address and entry.fill_monitor == target.name then',
'        target = nil',
'        placement = S.fallback',
'        break',
'      end',
'    end',
'  end',
'',
'  local sv = {',
'    monitor = home_monitor.name,',
'    workspace_id = home_workspace.id,',
'    workspace_name = home_workspace.name,',
'    fill_monitor = (target and placement == "fill") and target.name or nil,',
'    rule_key = rule_key(rule),',
'    placement = placement,',
'    floating = window.floating,',
'    fullscreen = window.fullscreen,',
'    fullscreen_client = window.fullscreen_client,',
'    at = { x = window.at.x, y = window.at.y },',
'    size = { x = window.size.x, y = window.size.y },',
'  }',
'  S.saved[window.address] = sv',
'',
'  -- pin silently no-ops on a fullscreen window while',
'  -- binds.allow_pin_fullscreen is off, so clear fullscreen first.',
'  if (window.fullscreen or 0) ~= 0 then',
'    hl.dispatch(hl.dsp.window.fullscreen_state({ window = selector, internal = 0, client = 0 }))',
'  end',
'',
'  sv.placed_on = (target or home_monitor).name',
'  sv.placed_at = placement',
'  place_float(window, sv, rule)',
'end',
'',
'local function pop_tile(window, rule)',
'  local home_monitor, home_workspace = window.monitor, window.workspace',
'  if not home_monitor or not home_workspace then return end',
'',
'  local selector = "address:" .. window.address',
'  local target = home_monitor',
'  if rule.monitor ~= "" then',
'    local m = hl.get_monitor(rule.monitor)',
'    if m then target = m end',
'  end',
'  local dest = target.active_workspace',
'  if not dest or dest.special then return end',
'',
'  S.saved[window.address] = {',
'    monitor = home_monitor.name,',
'    workspace_id = home_workspace.id,',
'    workspace_name = home_workspace.name,',
'    rule_key = rule_key(rule),',
'    placement = rule.placement,',
'    tiled = true,',
'    floating = window.floating,',
'    fullscreen = window.fullscreen,',
'    fullscreen_client = window.fullscreen_client,',
'    at = { x = window.at.x, y = window.at.y },',
'    size = { x = window.size.x, y = window.size.y },',
'  }',
'',
'  if (window.fullscreen or 0) ~= 0 then',
'    hl.dispatch(hl.dsp.window.fullscreen_state({ window = selector, internal = 0, client = 0 }))',
'  end',
'  if window.floating then',
'    hl.dispatch(hl.dsp.window.float({ window = selector, action = "off" }))',
'  end',
'  hl.dispatch(hl.dsp.window.move({ window = selector, workspace = dest.name, follow = false }))',
'  if rule.placement ~= "fill" then',
'    local sz = remembered(rule)',
'    local tw, th = geometry(target, rule.placement, sz)',
'    place_tiled(window.address, target, rule.placement, tw, th)',
'  end',
'end',
'',
'-- Carry a tiled pop-out onto whatever workspace just became visible.',
'local function carry(window, sv, rule)',
'  local m = window.monitor',
'  local active = m and m.active_workspace',
'  if not active or active.special then return end',
'  if window.workspace and window.workspace.id == active.id then return end',
'  local selector = "address:" .. window.address',
'  hl.dispatch(hl.dsp.window.move({ window = selector, workspace = active.name, follow = false }))',
'  if sv.placement and sv.placement ~= "fill" then',
'    local sz = remembered(rule)',
'    local tw, th = geometry(m, sv.placement, sz)',
'    place_tiled(window.address, m, sv.placement, tw, th)',
'  end',
'end',
'',
'local function restore(window, saved)',
'  local selector = "address:" .. window.address',
'  hl.dispatch(hl.dsp.window.pin({ window = selector, action = "off" }))',
'',
'  -- Unpinning only drops a window on whatever workspace is on screen, which is',
'  -- not enough once it has travelled to another display. Send it home by name;',
'  -- that reads the same for numbered and named workspaces.',
'  if saved.workspace_name then',
'    hl.dispatch(hl.dsp.window.move({ window = selector, workspace = saved.workspace_name, follow = false }))',
'  end',
'',
'  if saved.floating then',
'    -- Explicit action, so this is a no-op when it never stopped floating and',
'    -- a re-float for a window that spent its pop tiled.',
'    hl.dispatch(hl.dsp.window.float({ window = selector, action = "on" }))',
'    hl.dispatch(hl.dsp.window.resize({ window = selector, x = saved.size.x, y = saved.size.y, exact = true }))',
'    hl.dispatch(hl.dsp.window.move({ window = selector, x = saved.at.x, y = saved.at.y, exact = true }))',
'  else',
'    hl.dispatch(hl.dsp.window.float({ window = selector, action = "off" }))',
'  end',
'',
'  if (saved.fullscreen or 0) ~= 0 then',
'    hl.dispatch(hl.dsp.window.fullscreen_state({',
'      window = selector,',
'      internal = saved.fullscreen,',
'      client = saved.fullscreen_client or saved.fullscreen,',
'    }))',
'  end',
'',
'  S.saved[window.address] = nil',
'end',
'',
'-- SUPER+T on a tracked pop-out (wired in ~/.config/hypr/local.lua): zoom it',
'-- to half the display wide, 80% tall, centered -- and back where it was.',
'function S.toggle_big(address)',
'  local sv = S.saved[address]',
'  local window = hl.get_window("address:" .. address)',
'  if not sv or not window then return end',
'  local selector = "address:" .. address',
'',
'  if sv.big_prev then',
'    local prev = sv.big_prev',
'    sv.big_prev = nil',
'    if sv.tiled then',
'      hl.dispatch(hl.dsp.window.pin({ window = selector, action = "off" }))',
'      hl.dispatch(hl.dsp.window.float({ window = selector, action = "off" }))',
'      local m = window.monitor',
'      if m and sv.placement and sv.placement ~= "fill" then',
'        local rule = eligible(window)',
'        local tw, th = geometry(m, sv.placement, remembered(rule))',
'        place_tiled(address, m, sv.placement, tw, th)',
'      end',
'    else',
'      hl.dispatch(hl.dsp.window.resize({ window = selector, x = prev.w, y = prev.h, exact = true }))',
'      hl.dispatch(hl.dsp.window.move({ window = selector, x = prev.x, y = prev.y, exact = true }))',
'      sv.expected_w, sv.expected_h = prev.w, prev.h',
'    end',
'    return',
'  end',
'',
'  local m = window.monitor',
'  if not m then return end',
'  sv.big_prev = { x = window.at.x, y = window.at.y, w = window.size.x, h = window.size.y }',
'  local uw, uh, ux, uy = usable(m)',
'  local bw, bh = math.floor(uw * 0.5 + 0.5), math.floor(uh * 0.8 + 0.5)',
'  if sv.tiled then',
'    hl.dispatch(hl.dsp.window.float({ window = selector, action = "on" }))',
'    -- Pinned while zoomed, so a workspace switch cannot strand it.',
'    hl.dispatch(hl.dsp.window.pin({ window = selector, action = "on" }))',
'  end',
'  hl.dispatch(hl.dsp.window.resize({ window = selector, x = bw, y = bh, exact = true }))',
'  hl.dispatch(hl.dsp.window.move({',
'    window = selector,',
'    x = math.floor(ux + (uw - bw) / 2 + 0.5),',
'    y = math.floor(uy + (uh - bh) / 2 + 0.5),',
'    exact = true,',
'  }))',
'  hl.dispatch(hl.dsp.window.alter_zorder({ window = selector, mode = "top" }))',
'end',
'',
'-- Tile a pop-out into the workspace now visible on its monitor, and adopt',
'-- that workspace as its home. From here the ordinary machinery takes over:',
'-- leaving re-floats it to the configured corner, returning re-tiles it.',
'local function dock_here(window, sv, rule)',
'  local m = window.monitor',
'  local dest = m and m.active_workspace',
'  if not dest or dest.special then return false end',
'  local selector = "address:" .. window.address',
'  sv.workspace_id = dest.id',
'  sv.workspace_name = dest.name',
'  sv.dock = true',
'  sv.big_prev = nil',
'  hl.dispatch(hl.dsp.window.pin({ window = selector, action = "off" }))',
'  -- Unpinning drops the window on the focused workspace, which is not',
'  -- necessarily this one, so send it to the dock target explicitly before',
'  -- it tiles.',
'  hl.dispatch(hl.dsp.window.move({ window = selector, workspace = dest.name, follow = false }))',
'  hl.dispatch(hl.dsp.window.float({ window = selector, action = "off" }))',
'  if sv.placed_at and sv.placed_at ~= "fill" then',
'    local tw, th = geometry(m, sv.placed_at, remembered(rule))',
'    place_tiled(window.address, m, sv.placed_at, tw, th)',
'  end',
'  sv.tiled = true',
'  return true',
'end',
'',
'-- SUPER+O: pop the focused window out now (to its rule destination) or put it',
'-- back. Returns false when the window has no rule and is not already a pop, so',
'-- the keybind can fall back to the stock float-and-pin.',
'function S.toggle_pop(address)',
'  local window = hl.get_window("address:" .. address)',
'  if not window then return false end',
'  local sv = S.saved[address]',
'  if sv then',
'    if sv.dock then',
'      -- A docked window that is currently tiled at home has no saved float',
'      -- geometry to snap back to, so releasing it just untracks and unfloats.',
'      hl.dispatch(hl.dsp.window.pin({ window = "address:" .. address, action = "off" }))',
'      if window.floating then hl.dispatch(hl.dsp.window.float({ window = "address:" .. address, action = "off" })) end',
'      S.saved[address] = nil',
'    else',
'      restore(window, sv)',
'    end',
'    return true',
'  end',
'  local rule = eligible(window)',
'  if not rule then return false end',
'  if rule.tile then pop_tile(window, rule) else pop_float(window, rule) end',
'  return true',
'end',
'',
'-- SUPER+T on a pop-out: dock it into the current workspace, or undock back to',
'-- a floating pop. Returns false when the window is not a tracked pop, so the',
'-- keybind falls through to the stock float toggle for ordinary windows.',
'function S.toggle_dock(address)',
'  local window = hl.get_window("address:" .. address)',
'  local sv = window and S.saved[address]',
'  if not sv then return false end',
'  local rule = eligible(window)',
'  if sv.dock and not window.floating then',
'    -- Docked and sitting tiled at home: undock to a floating pop that follows.',
'    sv.dock = false',
'    place_float(window, sv, rule)',
'  else',
'    dock_here(window, sv, rule)',
'  end',
'  return true',
'end',
'',
'local function evaluate()',
'  local seen = {}',
'',
'  for _, window in ipairs(hl.get_windows()) do',
'    seen[window.address] = true',
'    local sv = S.saved[window.address]',
'',
'    if sv then',
'      -- Changed by hand behind our back (a manual unpin, or floating a tiled',
'      -- pop-out): whoever did that owns the window now, so drop the',
'      -- bookkeeping rather than springing a restore on them later.',
'      local taken',
'      if sv.dock then',
'        -- A dock oscillates tiled<->floating by design, so it is never judged',
'        -- taken here; SUPER+T or a manual unpin is how you let it go.',
'        taken = false',
'      elseif sv.big_prev then',
'        taken = not window.pinned',
'      elseif sv.tiled then',
'        taken = window.floating',
'      else',
'        taken = not window.pinned',
'      end',
'',
'      if taken then',
'        S.saved[window.address] = nil',
'      else',
'        local rule = eligible(window)',
'        local home = hl.get_monitor(sv.monitor)',
'        local home_active = home and home.active_workspace',
'        local at_home = home_active and home_active.id == sv.workspace_id',
'        if sv.dock then',
'          if at_home then',
'            -- Back on the docked workspace: re-tile if we floated away.',
'            if window.floating then',
'              hl.dispatch(hl.dsp.window.pin({ window = "address:" .. window.address, action = "off" }))',
'              hl.dispatch(hl.dsp.window.float({ window = "address:" .. window.address, action = "off" }))',
'              if sv.placed_at and sv.placed_at ~= "fill" then',
'                local tw, th = geometry(home, sv.placed_at, remembered(rule))',
'                place_tiled(window.address, home, sv.placed_at, tw, th)',
'              end',
'              sv.tiled = true',
'            end',
'          elseif not window.floating then',
'            -- Left the docked workspace while tiled: float out to the corner.',
'            place_float(window, sv, rule)',
'            -- For a stay window the dock is only ever a park-here-for-now: once',
'            -- you leave, it reverts to the plain floating pop that stay means,',
'            -- and does not re-tile on return (press SUPER+T again to re-dock).',
'            if rule and rule.stay then sv.dock = false end',
'          end',
'        elseif at_home and not (rule and rule.stay) then',
'          restore(window, sv)',
'        elseif sv.tiled and not sv.big_prev then',
'          carry(window, sv, rule)',
'        end',
'      end',
'    elseif not window.pinned then',
'      -- A window pinned by hand is left alone.',
'      local rule = eligible(window)',
'      local monitor = window.monitor',
'      local workspace = window.workspace',
'      local active = monitor and monitor.active_workspace',
'      if rule and active and workspace and not workspace.special',
'          and active.id ~= workspace.id then',
'        if rule.tile then pop_tile(window, rule) else pop_float(window, rule) end',
'      end',
'    end',
'  end',
'',
'  for address in pairs(S.saved) do',
'    if not seen[address] then S.saved[address] = nil end',
'  end',
'end',
'',
'-- Hyprland emits no resize event, so a hand-resized pop-out is noticed by',
'-- sampling. Floating corners only: a tiled pop-out is resized by the layout',
'-- every time its neighbours change, which says nothing about what the user',
'-- wants. The oneshot chain (instead of a repeat timer) dies with its',
'-- generation, so re-applies never accumulate samplers.',
'local function sample()',
'  if S.gen ~= gen then return end',
'  for address, sv in pairs(S.saved) do',
'    if not sv.big_prev and not sv.tiled and sv.placement and sv.placement ~= "fill" then',
'      local w = hl.get_window("address:" .. address)',
'      if w and w.pinned and sv.expected_w',
'          and (w.size.x ~= sv.expected_w or w.size.y ~= sv.expected_h) then',
'        sv.expected_w, sv.expected_h = w.size.x, w.size.y',
'        if sv.rule_key then',
'          S.sizes[sv.rule_key] = { w = w.size.x, h = w.size.y }',
'          persist_sizes()',
'        end',
'      end',
'    end',
'  end',
'  hl.timer(sample, { timeout = 1500, type = "oneshot" })',
'end',
'hl.timer(sample, { timeout = 1500, type = "oneshot" })',
'',
'S.sub = hl.on("workspace.active", function()',
'  -- The monitor\'s active_workspace is not settled while the event fires, and',
'  -- the delay coalesces a burst of switches into one evaluation.',
'  hl.timer(evaluate, { timeout = 60, type = "oneshot" })',
'end)'
        ].join("\n")
    }

    // ------------------------------------------------------------------ apply

    // hyprctl reports a Lua error by printing it and still exiting 0, so the
    // output is the only signal that the engine failed to install.
    Process {
        id: applyProc
        stdout: StdioCollector {
            onStreamFinished: {
                var reply = String(text).trim()
                if (reply.length && reply !== "ok")
                    console.warn("hyprpin: hyprctl eval said:", reply.slice(0, 400))
            }
        }
    }
    Process { id: ensureDirProc; command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/omarchy"] }

    function apply() {
        // Setting running on an already-running Process is a no-op and would
        // silently drop this apply. hyprctl eval returns in milliseconds, so
        // simply coming back around is enough.
        if (applyProc.running) {
            settle.restart()
            return
        }
        applyProc.command = ["hyprctl", "eval", root.lua()]
        applyProc.running = true
    }

    // Coalesces bursts: a settings change, a rules-file save and a Hyprland
    // config reload can all land together.
    Timer {
        id: settle
        interval: 250
        onTriggered: root.apply()
    }

    function applySoon() { settle.restart() }

    // A Hyprland config reload recreates its entire Lua state, taking the event
    // subscription with it. Without this the engine would quietly stop after
    // any `hyprctl reload` until the shell happened to restart.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event && event.name === "configreloaded")
                root.applySoon()
        }
    }

    onSettingsChanged: applySoon()

    Component.onCompleted: {
        ensureDirProc.running = true
        rulesFile.reload()
        applySoon()
    }
}
