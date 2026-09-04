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
    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
    readonly property string statePath: stateDir + "/hyprpin.json"
    // Remembered pop-out sizes: written by the engine (it is the side that
    // notices a hand resize), read back only by this service, as data.
    readonly property string sizesPath: stateDir + "/hyprpin-sizes.json"

    // State files live in a user-writable directory, so nothing here loads one
    // wholesale into the shell. statefile.py opens a file once with
    // O_NOFOLLOW|O_NONBLOCK, validates the descriptor (regular, owned by us,
    // within the byte limit) and reads only through it.
    readonly property string helperPath: {
        var url = Qt.resolvedUrl("statefile.py").toString()
        return url.indexOf("file://") === 0 ? url.slice(7) : url
    }

    // hyprctl needs only these to find its socket; everything else inherited
    // from the shell's environment stays out of child processes.
    readonly property var hyprctlEnv: ({
        HYPRLAND_INSTANCE_SIGNATURE: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
        XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR") || "",
        HOME: Quickshell.env("HOME") || ""
    })

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

    // The global switch, kept in the same state file as the rules. Off means
    // the engine stops matching entirely and hands every pop-out back; the
    // rules themselves are untouched, so turning it back on resumes as before.
    // A file without the key (every file written before the switch existed)
    // reads as on.
    property bool enabled: true

    // Everything here comes off disk and is editable by hand, so it is treated
    // as untrusted: shapes are checked, strings are bounded, and the monitor
    // name and placement are whitelisted rather than sanitised.
    function parseState(raw) {
        var none = { enabled: true, rules: [] }
        if (typeof raw !== "string" || raw.length === 0 || raw.length > 262144)
            return none
        var parsed
        try {
            parsed = JSON.parse(raw)
        } catch (e) {
            console.warn("hyprpin: rules file is not valid JSON, ignoring it")
            return none
        }
        if (!parsed || typeof parsed !== "object")
            return none
        var enabled = parsed.enabled !== false
        if (!Array.isArray(parsed.rules))
            return { enabled: enabled, rules: [] }

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
            if (placement !== "fill" && placement !== "special" && placements.indexOf(placement) < 0)
                continue
            out.push({
                "class": cls, title: title, monitor: monitor, placement: placement,
                stay: r.stay === true, tile: r.tile === true
            })
        }
        return { enabled: enabled, rules: out }
    }

    // Remembered pop-out sizes, as validated data. Injected into the engine
    // chunk; the engine itself never reads a file.
    property var sizes: []

    function parseSizes(raw) {
        if (typeof raw !== "string" || raw.length === 0 || raw.length > 32768)
            return []
        var parsed
        try {
            parsed = JSON.parse(raw)
        } catch (e) {
            console.warn("hyprpin: sizes file is not valid JSON, ignoring it")
            return []
        }
        if (!parsed || !Array.isArray(parsed.entries))
            return []
        var out = []
        for (var i = 0; i < parsed.entries.length && out.length < 64; i++) {
            var e = parsed.entries[i]
            if (!e || typeof e !== "object")
                continue
            var cls = typeof e["class"] === "string" ? e["class"] : ""
            var title = typeof e.title === "string" ? e.title : ""
            if (!cls.length || cls.length > 256 || title.length > 256)
                continue
            if (typeof e.w !== "number" || typeof e.h !== "number"
                    || !isFinite(e.w) || !isFinite(e.h))
                continue
            var w = Math.floor(e.w)
            var h = Math.floor(e.h)
            if (w < 100 || w > 16384 || h < 60 || h > 16384)
                continue
            out.push({ "class": cls, title: title, w: w, h: h })
        }
        return out
    }

    // ---------------------------------------------------------------- file io
    //
    // The FileView never loads content -- pointed at the state directory, its
    // load fails by design and only the change watcher is used. Every writer
    // of these files publishes by atomic rename, which is a directory-entry
    // change, so this fires for each of them. Content then comes through the
    // bounded helper.

    FileView {
        path: root.stateDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.rereadSoon()
    }

    // The directory watcher fires for every file in the shared state dir, so
    // reads are coalesced and results compared before anything re-applies.
    Timer {
        id: rereadSettle
        interval: 250
        onTriggered: { rulesReadProc.start(); sizesReadProc.start() }
    }

    function rereadSoon() { rereadSettle.restart() }

    property bool rulesReadOnce: false
    property bool sizesReadOnce: false

    Process {
        id: rulesReadProc
        command: ["/usr/bin/python3", "-I", root.helperPath, "read", root.statePath, "262144"]
        clearEnvironment: true
        property int code: -1
        property bool streamDone: false
        property string payload: ""
        property bool rerun: false
        stdout: StdioCollector {
            onStreamFinished: {
                rulesReadProc.payload = String(text)
                rulesReadProc.streamDone = true
                rulesReadProc.finishRead()
            }
        }
        onExited: function (exitCode) { code = exitCode; finishRead() }
        function start() {
            if (running) { rerun = true; return }
            code = -1; streamDone = false; payload = ""
            running = true
        }
        function finishRead() {
            if (code < 0 || !streamDone)
                return
            var next = code === 0 ? root.parseState(payload) : { enabled: true, rules: [] }
            var current = { enabled: root.enabled, rules: root.rules }
            if (code !== 0 && code !== 3) {
                console.warn("hyprpin: rules read refused (exit " + code + "), keeping current rules")
            } else if (root.rulesReadOnce && JSON.stringify(next) === JSON.stringify(current)) {
                // Unchanged; the watcher fired for some other file in the dir.
            } else {
                root.enabled = next.enabled
                root.rules = next.rules
                root.rulesReadOnce = true
                root.applySoon()
            }
            payload = ""
            if (rerun) { rerun = false; start() }
        }
    }

    Process {
        id: sizesReadProc
        command: ["/usr/bin/python3", "-I", root.helperPath, "read", root.sizesPath, "32768"]
        clearEnvironment: true
        property int code: -1
        property bool streamDone: false
        property string payload: ""
        property bool rerun: false
        stdout: StdioCollector {
            onStreamFinished: {
                sizesReadProc.payload = String(text)
                sizesReadProc.streamDone = true
                sizesReadProc.finishRead()
            }
        }
        onExited: function (exitCode) { code = exitCode; finishRead() }
        function start() {
            if (running) { rerun = true; return }
            code = -1; streamDone = false; payload = ""
            running = true
        }
        function finishRead() {
            if (code < 0 || !streamDone)
                return
            var next = code === 0 ? root.parseSizes(payload) : []
            if (code !== 0 && code !== 3) {
                console.warn("hyprpin: sizes read refused (exit " + code + "), keeping current sizes")
            } else if (root.sizesReadOnce && JSON.stringify(next) === JSON.stringify(root.sizes)) {
                // Unchanged.
            } else {
                root.sizes = next
                root.sizesReadOnce = true
                root.applySoon()
            }
            payload = ""
            if (rerun) { rerun = false; start() }
        }
    }

    // A stuck helper is killed rather than trusted to finish; the readers are
    // re-armed by the next directory change.
    Timer {
        id: readWatchdog
        interval: 10000
        repeat: true
        running: rulesReadProc.running || sizesReadProc.running
        onTriggered: {
            if (rulesReadProc.running) rulesReadProc.signal(9)
            if (sizesReadProc.running) sizesReadProc.signal(9)
        }
    }

    // ------------------------------------------------------------- Lua output

    function luaString(value, maxLen) {
        var s = typeof value === "string" ? value : ""
        var cap = maxLen === undefined ? 256 : maxLen
        if (s.length > cap)
            s = s.slice(0, cap)
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

    // Sizes are keyed the same way the engine keys them: class .. \031 .. title.
    // Both halves were already capped at 256 by parseSizes, so the key cap of
    // 520 only guards the joined form.
    function sizesLua() {
        var parts = []
        for (var i = 0; i < sizes.length; i++) {
            var s = sizes[i]
            parts.push("  [" + luaString(s["class"] + "\u001F" + s.title, 520)
                + "] = { w = " + s.w + ", h = " + s.h + " },")
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
'-- The global switch. Off short-circuits everything the engine would do on',
'-- its own -- no matching, no pops, no carries -- and the keybinds fall',
'-- through to their stock behaviour. The rules stay loaded so nothing is',
'-- lost; the sweep at the end of this chunk hands existing pop-outs back.',
'S.enabled = ' + (enabled ? "true" : "false"),
'S.width_fraction = ' + (cornerWidthPercent / 100),
'S.min_width = ' + cornerMinWidth,
'S.margin = ' + margin,
'S.aspect = 16 / 9',
'S.fallback = ' + luaString(fallbackPlacement),
'-- The "Scratchpad" placement parks a window here instead of showing it.',
'-- Omarchy binds SUPER+S and SUPER+grave to toggle this one, so a parked',
'-- window is a keypress away on whichever monitor you are looking at.',
'S.special = "special:scratchpad"',
'S.sizes_path = ' + luaString(sizesPath, 512),
'',
'local function rule_key(rule)',
'  return rule.class .. "\\031" .. (rule.title or "")',
'end',
'',
'-- Sizes the user gave pop-outs by hand, keyed per rule. Injected by the',
'-- service, which reads the JSON state file through a bounded no-follow',
'-- descriptor and validates every field; the engine itself never loads a',
'-- file, so no replaceable path can feed it code or unbounded data.',
'S.sizes = {',
sizesLua(),
'}',
'',
'-- Persisting is the mirror image: plain JSON, staged next to the',
'-- destination and published by rename, so the service never sees a torn',
'-- file and a link planted at the destination is replaced, not followed.',
'-- Lua\'s io cannot open exclusively, so the staging name is per-generation',
'-- and cleared first; entries are capped with live rules kept first.',
'local function json_escape(s)',
'  return (s:gsub(\'[\\0-\\31\\\\"]\', function(c)',
'    return string.format("\\\\u%04x", string.byte(c))',
'  end))',
'end',
'',
'local function persist_sizes()',
'  local keys = {}',
'  local live = {}',
'  for _, r in ipairs(S.rules) do live[rule_key(r)] = true end',
'  for k in pairs(S.sizes) do if live[k] then keys[#keys + 1] = k end end',
'  for k in pairs(S.sizes) do',
'    if not live[k] and #keys < 64 then keys[#keys + 1] = k end',
'  end',
'  local parts = {}',
'  for i = 1, math.min(#keys, 64) do',
'    local v = S.sizes[keys[i]]',
'    local class, title = keys[i]:match("^(.*)\\031(.*)$")',
'    if class and tonumber(v.w) and tonumber(v.h) then',
'      parts[#parts + 1] = string.format(',
'        \'    { "class": "%s", "title": "%s", "w": %d, "h": %d }\',',
'        json_escape(class), json_escape(title), v.w, v.h)',
'    end',
'  end',
'  local staging = S.sizes_path .. ".gen" .. tostring(S.gen)',
'  os.remove(staging)',
'  local f = io.open(staging, "w")',
'  if not f then return end',
'  f:write(\'{\\n  "version": 1,\\n  "entries": [\\n\')',
'  f:write(table.concat(parts, ",\\n"))',
'  f:write(\'\\n  ]\\n}\\n\')',
'  f:close()',
'  os.rename(staging, S.sizes_path)',
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
'local pop_tile',
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
'-- Hide the window in the scratchpad rather than showing it anywhere. Same',
'-- bookkeeping as a float pop so restore() brings it home by name; no pin,',
'-- no geometry. Split out so the dock/undock paths can re-park it.',
'local function park_special(window, sv)',
'  local selector = "address:" .. window.address',
'  if (window.fullscreen or 0) ~= 0 then',
'    hl.dispatch(hl.dsp.window.fullscreen_state({ window = selector, internal = 0, client = 0 }))',
'  end',
'  hl.dispatch(hl.dsp.window.move({ window = selector, workspace = S.special, follow = false }))',
'  sv.tiled = false',
'end',
'',
'-- Returns false when the window already sits on a special workspace: there',
'-- is nowhere to bring it home to, so the manual pop falls through to stock.',
'local function pop_special(window, rule)',
'  local home_monitor, home_workspace = window.monitor, window.workspace',
'  if not home_monitor or not home_workspace or home_workspace.special then return false end',
'  local sv = {',
'    monitor = home_monitor.name,',
'    workspace_id = home_workspace.id,',
'    workspace_name = home_workspace.name,',
'    rule_key = rule_key(rule),',
'    placement = "special",',
'    special = true,',
'    floating = window.floating,',
'    fullscreen = window.fullscreen,',
'    fullscreen_client = window.fullscreen_client,',
'    at = { x = window.at.x, y = window.at.y },',
'    size = { x = window.size.x, y = window.size.y },',
'  }',
'  S.saved[window.address] = sv',
'  park_special(window, sv)',
'  return true',
'end',
'',
'-- One entry point for "pop this window out per its rule", whatever the rule',
'-- asks for. Tiled wins over the placement kept underneath it.',
'local function pop(window, rule)',
'  if rule.tile then pop_tile(window, rule) return true end',
'  if rule.placement == "special" then return pop_special(window, rule) end',
'  pop_float(window, rule)',
'  return true',
'end',
'',
'function pop_tile(window, rule)',
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
'-- Let go of a tracked window entirely: put it back where it came from and',
'-- forget it. A docked window that is tiled at home has no saved float',
'-- geometry to snap back to, so releasing it just untracks and unfloats.',
'local function release(window, sv)',
'  if sv.dock then',
'    local selector = "address:" .. window.address',
'    hl.dispatch(hl.dsp.window.pin({ window = selector, action = "off" }))',
'    if window.floating then hl.dispatch(hl.dsp.window.float({ window = selector, action = "off" })) end',
'    S.saved[window.address] = nil',
'  else',
'    restore(window, sv)',
'  end',
'end',
'',
'-- SUPER+T on a tracked pop-out (wired in ~/.config/hypr/local.lua): zoom it',
'-- to half the display wide, 80% tall, centered -- and back where it was.',
'function S.toggle_big(address)',
'  local sv = S.saved[address]',
'  local window = hl.get_window("address:" .. address)',
'  if not sv or not window or sv.special then return end',
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
'  if not S.enabled then return false end',
'  local window = hl.get_window("address:" .. address)',
'  if not window then return false end',
'  local sv = S.saved[address]',
'  if sv then',
'    release(window, sv)',
'    return true',
'  end',
'  local rule = eligible(window)',
'  if not rule then return false end',
'  return pop(window, rule)',
'end',
'',
'-- SUPER+T on a pop-out: dock it into the current workspace, or undock back to',
'-- a floating pop. Returns false when the window is not a tracked pop, so the',
'-- keybind falls through to the stock float toggle for ordinary windows.',
'function S.toggle_dock(address)',
'  if not S.enabled then return false end',
'  local window = hl.get_window("address:" .. address)',
'  local sv = window and S.saved[address]',
'  if not sv then return false end',
'  local rule = eligible(window)',
'  if sv.dock and not window.floating then',
'    -- Docked and sitting tiled at home: undock to the pop that follows.',
'    sv.dock = false',
'    if sv.special then park_special(window, sv) else place_float(window, sv, rule) end',
'  else',
'    dock_here(window, sv, rule)',
'  end',
'  return true',
'end',
'',
'local function evaluate()',
'  if not S.enabled then return end',
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
'      elseif sv.special then',
'        -- Pulled out of the scratchpad by hand (SUPER+ALT+S, or a drag).',
'        taken = not (window.workspace and window.workspace.special)',
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
'            -- Back on the docked workspace: re-tile if we floated away (or',
'            -- were parked in the scratchpad meanwhile).',
'            local parked = sv.special and window.workspace and window.workspace.special',
'            if window.floating or parked then',
'              hl.dispatch(hl.dsp.window.pin({ window = "address:" .. window.address, action = "off" }))',
'              hl.dispatch(hl.dsp.window.move({ window = "address:" .. window.address, workspace = sv.workspace_name, follow = false }))',
'              hl.dispatch(hl.dsp.window.float({ window = "address:" .. window.address, action = "off" }))',
'              if sv.placed_at and sv.placed_at ~= "fill" then',
'                local tw, th = geometry(home, sv.placed_at, remembered(rule))',
'                place_tiled(window.address, home, sv.placed_at, tw, th)',
'              end',
'              sv.tiled = true',
'            end',
'          elseif not window.floating then',
'            -- Left the docked workspace while tiled: float out to the corner',
'            -- (or back into the scratchpad for a rule that parks there).',
'            if sv.special then park_special(window, sv) else place_float(window, sv, rule) end',
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
'        pop(window, rule)',
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
'    if not sv.big_prev and not sv.tiled and not sv.special and sv.placement and sv.placement ~= "fill" then',
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
'-- A rule removed from the panel takes its pop-out with it, now rather than',
'-- on some later workspace switch, and switching the whole plugin off takes',
'-- every pop-out with it. Matching is by rule identity, not by re-running',
'-- eligible(): a window whose title drifted out of pattern match mid-call',
'-- must not be yanked home, and a hand-popped window has no rule_key and is',
'-- never a candidate.',
'do',
'  local live = {}',
'  for _, r in ipairs(S.rules) do live[rule_key(r)] = true end',
'  for address, sv in pairs(S.saved) do',
'    if not S.enabled or (sv.rule_key and not live[sv.rule_key]) then',
'      local w = hl.get_window("address:" .. address)',
'      if w then release(w, sv) else S.saved[address] = nil end',
'    end',
'  end',
'end',
'',
'-- Switching back on evaluates now rather than on the next workspace switch,',
'-- so a call whose workspace is already hidden pops straight back out. Only',
'-- on the off->on edge: an ordinary re-apply (settings, a rules save) keeps',
'-- its hands off the layout.',
'if S.enabled and S.was_enabled == false then',
'  hl.timer(evaluate, { timeout = 60, type = "oneshot" })',
'end',
'S.was_enabled = S.enabled',
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
    // output is the only signal that the engine failed to install. hyprctl is
    // the only producer on this pipe and its reply to eval is a short status,
    // so the collector is bounded by the producer; the log line is capped
    // anyway, and the watchdog below kills a wedged run.
    Process {
        id: applyProc
        clearEnvironment: true
        environment: root.hyprctlEnv
        stdout: StdioCollector {
            onStreamFinished: {
                var reply = String(text).trim()
                if (reply.length && reply !== "ok")
                    console.warn("hyprpin: hyprctl eval said:", reply.slice(0, 400))
            }
        }
    }

    Timer {
        interval: 10000
        repeat: true
        running: applyProc.running
        onTriggered: {
            console.warn("hyprpin: hyprctl eval exceeded its deadline, killing it")
            applyProc.signal(9)
        }
    }

    function apply() {
        // Setting running on an already-running Process is a no-op and would
        // silently drop this apply. hyprctl eval returns in milliseconds, so
        // simply coming back around is enough.
        if (applyProc.running) {
            settle.restart()
            return
        }
        applyProc.command = ["/usr/bin/hyprctl", "eval", root.lua()]
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
        // First run: no state files yet. The readers report that distinctly
        // and still apply, so a config reload does not leave a previously
        // popped window stranded with no engine to restore it.
        rulesReadProc.start()
        sizesReadProc.start()
        applySoon()
    }
}
