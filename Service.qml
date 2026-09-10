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
    // Initial thickness of a tiled-edge pop-out, as a percentage of the
    // display along the docked axis. The stripe follows a hand resize after
    // that, so this is only where a new dock starts.
    readonly property int edgeSizePercent: clampInt(setting("edgeSizePercent", 34), 10, 60, 34)

    readonly property var placements: ["bottom-right", "bottom-left", "top-right", "top-left"]
    // Tiled placements: the window takes a reserved stripe on one edge of the
    // display and the tiling layout gets the rest.
    readonly property var edges: ["tile-left", "tile-right", "tile-top", "tile-bottom"]
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
            // Files written before the tiled edges existed carried a `tile`
            // flag on top of a corner; that mode is gone, and the nearest
            // thing to it is the right edge.
            if (r.tile === true && edges.indexOf(placement) < 0)
                placement = "tile-right"
            if (placement !== "fill" && placement !== "special"
                    && placements.indexOf(placement) < 0 && edges.indexOf(placement) < 0)
                continue
            out.push({
                "class": cls, title: title, monitor: monitor, placement: placement,
                stay: r.stay === true
            })
        }
        return { enabled: enabled, rules: out }
    }

    // Remembered sizes and monitor-relative float positions, injected as
    // validated data; the engine itself never reads a file.
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
            var entry = { "class": cls, title: title, w: w, h: h }
            var f = e.floating
            if (f && typeof f === "object" && !Array.isArray(f)
                    && ["free", "fill", "top-left", "top-right", "bottom-left", "bottom-right"].indexOf(f.placement) >= 0
                    && typeof f.x === "number" && isFinite(f.x) && f.x >= 0 && f.x <= 1
                    && typeof f.y === "number" && isFinite(f.y) && f.y >= 0 && f.y <= 1
                    && typeof f.w === "number" && isFinite(f.w) && f.w >= 100 && f.w <= 16384
                    && typeof f.h === "number" && isFinite(f.h) && f.h >= 60 && f.h <= 16384) {
                entry.floating = { placement: f.placement, x: f.x, y: f.y,
                    w: Math.floor(f.w), h: Math.floor(f.h) }
            }
            out.push(entry)
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
    property int rulesRevision: 0
    readonly property string cycleSession: Date.now().toString(36) + Math.random().toString(36).slice(2)
    property var cycleReply: null
    property var cycleReadback: null
    property var cycleResync: null
    property var applyReceipt: null
    property int applyFailures: 0

    // A compositor event carries only a bounded rule index and snapshot ID.
    // Rule text travels to the writer on stdin, never through an executable
    // command string. Save against the latest file before moving the window.
    function handleCycle(raw) {
        if (typeof raw !== "string" || raw.length > 1024 || cycleWriteProc.running || cycleReply || cycleReadback)
            return
        var request
        try { request = JSON.parse(raw) } catch (e) { return }
        if (!request || typeof request.session !== "string" || request.session.length > 64
                || !Number.isInteger(request.revision) || request.revision < 0
                || !Number.isInteger(request.token) || request.token < 1 || request.token > 1000000000
                || !Number.isInteger(request.index) || request.index < 0 || request.index >= 64
                || ["tile-right", "tile-bottom", "tile-left", "tile-top", "top-right", "bottom-right", "bottom-left", "top-left", "special"].indexOf(request.next) < 0)
            return
        if (request.session !== cycleSession || request.revision !== rulesRevision) {
            // Never write from an outdated index. Refresh the engine first;
            // its pending token and rule identity decide whether to resend.
            cycleResync = request.token
            applyFailures = 0
            applySoon()
            return
        }
        if (request.index >= rules.length)
            return
        var rule = rules[request.index]
        if (rule.placement !== request.previous)
            return
        cycleWriteProc.token = request.token
        cycleWriteProc.payload = JSON.stringify({ "class": rule["class"], title: rule.title,
            previous: rule.placement, next: request.next })
        cycleWriteProc.running = true
    }

    function finishCycleWrite(token, exitCode) {
        // An older directory-watch read may still be finishing. Only a read
        // started after this write can confirm the new placement. Keep its
        // reply out of apply() until that fresh snapshot is available.
        cycleReadback = { token: token, success: exitCode === 0, after: rulesReadProc.readSerial }
        if (exitCode !== 0)
            console.warn("hyprpin: placement save failed (exit " + exitCode + ")")
        rulesReadProc.start()
    }

    Process {
        id: cycleWriteProc
        command: ["/usr/bin/python3", "-I", root.helperPath, "placement", root.statePath, "262144"]
        clearEnvironment: true
        stdinEnabled: true
        property int token: 0
        property string payload: ""
        onStarted: {
            write(payload)
            payload = ""
            stdinEnabled = false
        }
        onExited: function(exitCode) {
            stdinEnabled = true
            root.finishCycleWrite(token, exitCode)
        }
    }

    Timer {
        interval: 10000
        running: cycleWriteProc.running
        onTriggered: cycleWriteProc.signal(9)
    }

    Process {
        id: rulesReadProc
        command: ["/usr/bin/python3", "-I", root.helperPath, "read", root.statePath, "262144"]
        clearEnvironment: true
        property int code: -1
        property bool streamDone: false
        property string payload: ""
        property bool rerun: false
        property int readSerial: 0
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
            readSerial = (readSerial + 1) % 1000000000
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
                root.rulesRevision++
                root.rulesReadOnce = true
                root.applySoon()
            }
            payload = ""
            if (root.cycleReadback && readSerial !== root.cycleReadback.after) {
                root.cycleReply = { token: root.cycleReadback.token,
                    success: root.cycleReadback.success && code === 0 }
                root.cycleReadback = null
                root.apply()
            }
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
                + ", stay = " + (r.stay ? "true" : "false") + " },")
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
            var f = s.floating
            var floating = f ? ", floating = { placement = " + luaString(f.placement)
                + ", x = " + f.x + ", y = " + f.y + ", w = " + f.w + ", h = " + f.h + " }" : ""
            parts.push("  [" + luaString(s["class"] + "\u001F" + s.title, 520)
                + "] = { w = " + s.w + ", h = " + s.h + floating + " },")
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
'-- Re-applying must never stack a second handler on either event, and the',
'-- generation counter retires any sampler chain from a previous apply.',
'if S.sub then pcall(function() S.sub:remove() end) S.sub = nil end',
'if S.close_sub then pcall(function() S.close_sub:remove() end) S.close_sub = nil end',
'S.gen = (S.gen or 0) + 1',
'local gen = S.gen',
'-- Whatever is popped out right now stays tracked across a re-apply, so',
'-- changing a setting mid-call cannot strand a window.',
'S.saved = S.saved or {}',
'S.cycle_session = ' + luaString(cycleSession),
'S.rules_revision = ' + rulesRevision,
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
'S.edge_fraction = ' + (edgeSizePercent / 100),
'-- Runtime workspace rules can only be disabled, never removed, and their',
'-- handles live only here -- so both tables outlive a re-apply, or a new',
'-- generation could neither reuse nor take back a reservation.',
'S.gaps = S.gaps or {}',
'S.edge_rule = S.edge_rule or {}',
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
'  local parts, bytes = {}, 64',
'  for i = 1, math.min(#keys, 64) do',
'    local v = S.sizes[keys[i]]',
'    local class, title = keys[i]:match("^(.*)\\031(.*)$")',
'    if class and tonumber(v.w) and tonumber(v.h) then',
'      local floating = ""',
'      if v.floating then',
'        local f = v.floating',
'        floating = string.format(\', "floating": { "placement": "%s", "x": %.6f, "y": %.6f, "w": %d, "h": %d }\',',
'          json_escape(f.placement), f.x, f.y, f.w, f.h)',
'      end',
'      local entry = string.format(',
'        \'    { "class": "%s", "title": "%s", "w": %d, "h": %d%s }\',',
'        json_escape(class), json_escape(title), v.w, v.h, floating)',
'      -- Stay within the reader\'s byte contract even with escaped patterns.',
'      if bytes + #entry + 2 <= 32768 then',
'        parts[#parts + 1] = entry',
'        bytes = bytes + #entry + 2',
'      end',
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
'  w, h = math.min(w, uw), math.min(h, uh)',
'  local mx, my = math.min(S.margin, (uw - w) / 2), math.min(S.margin, (uh - h) / 2)',
'  local x = placement:find("left") and (ux + mx) or (ux + uw - w - mx)',
'  local y = placement:find("top") and (uy + my) or (uy + uh - h - my)',
'  return w, h, math.floor(x + 0.5), math.floor(y + 0.5)',
'end',
'',
'-- ---------------------------------------------------------- tiled edges',
'--',
'-- A "tiled" placement does not join the layout at all. The window floats,',
'-- pinned, in a stripe against one edge of the display, and a runtime',
'-- workspace rule pads that edge\'s outer gap by the stripe, so every tiling',
'-- layout on that display flows around it (the approach Omaperch takes,',
'-- and the stock Quake console). A workspace gap rule is used rather than',
'-- reserved monitor space because the latter also squeezes the bar. Scoped',
'-- to the one display with an m[] selector and kept off special workspaces,',
'-- which carry gap rules of their own.',
'local function edge_side(placement)',
'  return placement and placement:match("^tile%-(%a+)$") or nil',
'end',
'',
'-- The theme\'s own gaps, read live so a dock always lines up with the tiles',
'-- around it. Both gap options come back as per-edge tables.',
'local function gap_edges()',
'  local function edges(v, fb)',
'    if type(v) == "table" then',
'      return { top = tonumber(v.top) or fb, right = tonumber(v.right) or fb,',
'               bottom = tonumber(v.bottom) or fb, left = tonumber(v.left) or fb }',
'    end',
'    local n = tonumber(v) or fb',
'    return { top = n, right = n, bottom = n, left = n }',
'  end',
'  local go = hl.get_config("general:gaps_out")',
'  local gi = hl.get_config("general:gaps_in")',
'  local bs = hl.get_config("general:border_size")',
'  return edges(go, 10), edges(gi, 5), tonumber(bs) or 2',
'end',
'',
'local function between_gap(side)',
'  local _, inn = gap_edges()',
'  if side == "left" or side == "right" then return inn.left + inn.right end',
'  return inn.top + inn.bottom',
'end',
'',
'-- The docked window\'s rectangle for a stripe of `size` on `side`: the same',
'-- gaps_out + border inset a tile gets on the three outer edges, and one',
'-- between-tiles gap toward the layout, so it reads as one more tile.',
'local function edge_zone(monitor, side, size)',
'  local uw, uh, ux, uy = usable(monitor)',
'  local out, _, border = gap_edges()',
'  local between = between_gap(side)',
'  local w, h, x, y',
'  if side == "left" or side == "right" then',
'    w = size - between',
'    h = uh - out.top - out.bottom - 2 * border',
'    x = side == "right" and (ux + uw - out.right - border - w) or (ux + out.left + border)',
'    y = uy + out.top + border',
'  else',
'    w = uw - out.left - out.right - 2 * border',
'    h = size - between',
'    x = ux + out.left + border',
'    y = side == "top" and (uy + out.top + border) or (uy + uh - out.bottom - border - h)',
'  end',
'  return math.floor(w), math.floor(h), math.floor(x + 0.5), math.floor(y + 0.5)',
'end',
'',
'local function unreserve(name)',
'  local rule = S.edge_rule[name]',
'  if rule then',
'    pcall(function() rule:set_enabled(false) end)',
'    S.edge_rule[name] = nil',
'  end',
'end',
'',
'-- Pad one display\'s outer gap on `side` by `size`. hl.workspace_rule only',
'-- ever adds a rule and the result cannot be removed or edited, only toggled,',
'-- so each distinct geometry is declared once and re-enabled after that;',
'-- exactly one is enabled per display at a time.',
'local function reserve(name, side, size)',
'  unreserve(name)',
'  local out = gap_edges()',
'  local t, r, b, l = out.top, out.right, out.bottom, out.left',
'  if side == "top" then t = t + size',
'  elseif side == "right" then r = r + size',
'  elseif side == "bottom" then b = b + size',
'  else l = l + size end',
'  local key = name .. "|" .. t .. "_" .. r .. "_" .. b .. "_" .. l',
'  local rule = S.gaps[key]',
'  if rule then',
'    pcall(function() rule:set_enabled(true) end)',
'  else',
'    local ok, made = pcall(hl.workspace_rule, {',
'      workspace = "m[" .. name .. "] s[false]",',
'      gaps_out = { top = t, right = r, bottom = b, left = l },',
'    })',
'    if not ok or not made then return end',
'    rule = made',
'    S.gaps[key] = rule',
'  end',
'  S.edge_rule[name] = rule',
'end',
'',
'-- Releasing a stripe also clears its owner, so closing a detached pin',
'-- cannot disable a reservation subsequently acquired by another window.',
'local function release_edge(sv)',
'  if sv.edge_monitor then',
'    unreserve(sv.edge_monitor)',
'    sv.edge_monitor = nil',
'  end',
'end',
'',
'local function drop(address)',
'  local sv = S.saved[address]',
'  if sv then release_edge(sv) end',
'  S.saved[address] = nil',
'end',
'',
'local function edge_busy(address, monitor)',
'  for other, entry in pairs(S.saved) do',
'    if other ~= address and entry.edge_monitor == monitor then return true end',
'  end',
'  return false',
'end',
'',
'-- Keep a free rectangle separately from the edge thickness and zoom snapshot.',
'-- Positions are fractions of the available travel on the monitor, so a saved',
'-- spot follows display origin/scale changes and stays visible on smaller ones.',
'local function float_placement(sv)',
'  return sv.edge and "free" or sv.placed_at',
'end',
'',
'local function observed_float(window)',
'  return { x = window.at.x, y = window.at.y, w = window.size.x, h = window.size.y, monitor = window.monitor.name }',
'end',
'',
'local function float_geometry(monitor, sv, rule)',
'  local entry = sv.rule_key and S.sizes[sv.rule_key]',
'  local f = entry and entry.floating',
'  local uw, uh, ux, uy = usable(monitor)',
'  if f and f.placement == float_placement(sv) then',
'    local w, h = math.min(f.w, uw), math.min(f.h, uh)',
'    return w, h, math.floor(ux + (uw - w) * f.x + 0.5), math.floor(uy + (uh - h) * f.y + 0.5)',
'  end',
'  if sv.edge then',
'    -- First detach uses the normal corner size, centered. It is a starting',
'    -- point the user can move and resize, independent of the edge stripe.',
'    local w, h = geometry(monitor, S.fallback)',
'    w, h = math.min(w, uw), math.min(h, uh)',
'    return w, h, math.floor(ux + (uw - w) / 2 + 0.5), math.floor(uy + (uh - h) / 2 + 0.5)',
'  end',
'  return geometry(monitor, sv.placed_at or S.fallback, remembered(rule))',
'end',
'',
'local function remember_window(window, sv)',
'  if not sv.rule_key or sv.big_prev or sv.tiled or sv.special or not window.pinned',
'      or not window.floating or not window.monitor then return false end',
'  local w, h = math.floor(window.size.x), math.floor(window.size.y)',
'  if w < 100 or w > 16384 or h < 60 or h > 16384 then return false end',
'  local entry = S.sizes[sv.rule_key]',
'  if sv.edge and not sv.detached then',
'    if not sv.expected_w or (w == sv.expected_w and h == sv.expected_h) then return false end',
'    local sideways = sv.edge == "left" or sv.edge == "right"',
'    sv.edge_size = (sideways and w or h) + between_gap(sv.edge)',
'    entry = entry or {}',
'    entry.w, entry.h = w, h',
'    S.sizes[sv.rule_key] = entry',
'    persist_sizes()',
'    return true',
'  end',
'  local observed, last = observed_float(window), sv.float_observed',
'  if last and last.x == observed.x and last.y == observed.y and last.w == observed.w',
'      and last.h == observed.h and last.monitor == observed.monitor then return false end',
'  sv.float_observed = observed',
'  sv.cycle_slot, sv.cycle_remaining = nil, nil',
'  local uw, uh, ux, uy = usable(window.monitor)',
'  local function fraction(offset, travel)',
'    if travel <= 0 then return 0 end',
'    return math.floor(math.max(0, math.min(1, offset / travel)) * 1000000 + 0.5) / 1000000',
'  end',
'  local f = { placement = float_placement(sv), w = w, h = h,',
'    x = fraction(window.at.x - ux, uw - w), y = fraction(window.at.y - uy, uh - h) }',
'  local prev = entry and entry.floating',
'  if prev and prev.placement == f.placement and prev.w == w and prev.h == h',
'      and prev.x == f.x and prev.y == f.y then return false end',
'  -- The legacy w/h fields remain the edge\'s size, never the detached size.',
'  if not entry then',
'    local ew, eh = w, h',
'    if sv.edge then',
'      local target = (sv.placed_on and hl.get_monitor(sv.placed_on)) or window.monitor',
'      local tw, th = usable(target)',
'      local extent = (sv.edge == "left" or sv.edge == "right") and tw or th',
'      ew, eh = edge_zone(target, sv.edge, sv.edge_size or math.floor(extent * S.edge_fraction + 0.5))',
'    end',
'    entry = { w = ew, h = eh }',
'  end',
'  if not sv.edge then entry.w, entry.h = w, h end',
'  entry.floating = f',
'  S.sizes[sv.rule_key] = entry',
'  persist_sizes()',
'  return false',
'end',
'',
'-- Kept as a no-op hook: the dock-here path (SUPER+T) once nudged a tiled',
'-- window toward a corner, which walked it onto the neighbouring display',
'-- near an edge, so the layout places it.',
'local function place_tiled(address, monitor, placement, tw, th)',
'end',
'',
'-- Float the window to its configured corner/display and pin it. Split out so',
'-- the manual pop (SUPER+O), the dock toggle and the auto-pop all share it.',
'local function place_float(window, sv, rule)',
'  local selector = "address:" .. window.address',
'  local place_on = (sv.placed_on and hl.get_monitor(sv.placed_on)) or window.monitor',
'  if not place_on then return end',
'  if (window.fullscreen or 0) ~= 0 then',
'    hl.dispatch(hl.dsp.window.fullscreen_state({ window = selector, internal = 0, client = 0 }))',
'  end',
'  if place_on.name ~= (window.monitor and window.monitor.name) then',
'    hl.dispatch(hl.dsp.window.move({ window = selector, monitor = place_on.name, follow = false }))',
'  end',
'  local w, h, x, y',
'  if sv.cycle_anchor then',
'    w, h, x, y = geometry(place_on, sv.placed_at, sv.cycle_anchor)',
'    sv.cycle_anchor = nil',
'  else',
'    w, h, x, y = float_geometry(place_on, sv, rule)',
'  end',
'  hl.dispatch(hl.dsp.window.float({ window = selector, action = "on" }))',
'  hl.dispatch(hl.dsp.window.resize({ window = selector, x = w, y = h, exact = true }))',
'  hl.dispatch(hl.dsp.window.move({ window = selector, x = x, y = y, exact = true }))',
'  hl.dispatch(hl.dsp.window.pin({ window = selector, action = "on" }))',
'  hl.dispatch(hl.dsp.window.alter_zorder({ window = selector, mode = "top" }))',
'  sv.expected_w, sv.expected_h = w, h',
'  sv.placed_rect = { x = x, y = y, w = w, h = h, monitor = place_on.name }',
'  sv.float_observed = sv.placed_rect',
'  sv.tiled = false',
'end',
'',
'-- Float the window into its edge stripe, pin it, and reserve the stripe.',
'-- The stripe starts at the configured fraction (or the remembered size',
'-- from an earlier hand resize) and is clamped to a sane band of the axis.',
'local function place_edge(window, sv, rule)',
'  local selector = "address:" .. window.address',
'  local place_on = (sv.placed_on and hl.get_monitor(sv.placed_on)) or window.monitor',
'  if not place_on then return false end',
'  if edge_busy(window.address, place_on.name) then return false end',
'  local side = sv.edge or "right"',
'  local sideways = side == "left" or side == "right"',
'  if (window.fullscreen or 0) ~= 0 then',
'    hl.dispatch(hl.dsp.window.fullscreen_state({ window = selector, internal = 0, client = 0 }))',
'  end',
'  if place_on.name ~= (window.monitor and window.monitor.name) then',
'    hl.dispatch(hl.dsp.window.move({ window = selector, monitor = place_on.name, follow = false }))',
'  end',
'  local uw, uh = usable(place_on)',
'  local extent = sideways and uw or uh',
'  local size = sv.edge_size',
'  if not size then',
'    local sz = remembered(rule)',
'    if sz then size = (sideways and sz.w or sz.h) + between_gap(side)',
'    else size = math.floor(extent * S.edge_fraction + 0.5) end',
'  end',
'  size = math.max(math.floor(extent * 0.1), math.min(math.floor(extent * 0.6), size))',
'  sv.edge_size = size',
'  if sv.edge_monitor ~= place_on.name then release_edge(sv) end',
'  sv.edge_monitor = place_on.name',
'  local w, h, x, y = edge_zone(place_on, side, size)',
'  hl.dispatch(hl.dsp.window.float({ window = selector, action = "on" }))',
'  hl.dispatch(hl.dsp.window.resize({ window = selector, x = w, y = h, exact = true }))',
'  hl.dispatch(hl.dsp.window.move({ window = selector, x = x, y = y, exact = true }))',
'  hl.dispatch(hl.dsp.window.pin({ window = selector, action = "on" }))',
'  hl.dispatch(hl.dsp.window.alter_zorder({ window = selector, mode = "top" }))',
'  sv.expected_w, sv.expected_h = w, h',
'  sv.tiled, sv.detached = false, false',
'  reserve(place_on.name, side, size)',
'  return true',
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
'    rule_placement = rule.placement,',
'    rule_monitor = rule.monitor,',
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
'-- Put a tracked window wherever its bookkeeping says it goes.',
'local function place(window, sv, rule)',
'  if sv.special then park_special(window, sv)',
'  elseif sv.edge then',
'    if sv.detached or not place_edge(window, sv, rule) then',
'      sv.detached = true',
'      place_float(window, sv, rule)',
'    end',
'  else place_float(window, sv, rule) end',
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
'    rule_placement = rule.placement,',
'    rule_monitor = rule.monitor,',
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
'-- Dock the window into an edge stripe of its rule\'s display (or its own).',
'-- One edge dock per display: a later arrival floats until its edge is free.',
'local function pop_edge(window, rule)',
'  local home_monitor, home_workspace = window.monitor, window.workspace',
'  if not home_monitor or not home_workspace then return end',
'  local target = home_monitor',
'  if rule.monitor ~= "" then',
'    local m = hl.get_monitor(rule.monitor)',
'    if m then target = m end',
'  end',
'  local sv = {',
'    monitor = home_monitor.name,',
'    workspace_id = home_workspace.id,',
'    workspace_name = home_workspace.name,',
'    rule_key = rule_key(rule),',
'    rule_placement = rule.placement,',
'    rule_monitor = rule.monitor,',
'    placement = rule.placement,',
'    edge = edge_side(rule.placement),',
'    floating = window.floating,',
'    fullscreen = window.fullscreen,',
'    fullscreen_client = window.fullscreen_client,',
'    at = { x = window.at.x, y = window.at.y },',
'    size = { x = window.size.x, y = window.size.y },',
'  }',
'  S.saved[window.address] = sv',
'  sv.placed_on = target.name',
'  sv.placed_at = rule.placement',
'  place(window, sv, rule)',
'end',
'',
'-- One entry point for "pop this window out per its rule", whatever the rule',
'-- asks for.',
'local function pop(window, rule)',
'  if rule.placement == "special" then return pop_special(window, rule) end',
'  if edge_side(rule.placement) then pop_edge(window, rule) return true end',
'  pop_float(window, rule)',
'  return true',
'end',
'',
'local function restore(window, saved)',
'  remember_window(window, saved)',
'  local selector = "address:" .. window.address',
'  -- A window parked in the scratchpad was never pinned, and Hyprland logs a',
'  -- "does not qualify" warning for an unpin on a special workspace.',
'  if not saved.special then',
'    hl.dispatch(hl.dsp.window.pin({ window = selector, action = "off" }))',
'  end',
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
'  drop(window.address)',
'end',
'',
'-- Let go of a tracked window entirely: put it back where it came from and',
'-- forget it. Releasing a workspace dock leaves it tiled in its adopted home.',
'local function release(window, sv)',
'  remember_window(window, sv)',
'  if sv.dock then',
'    local selector = "address:" .. window.address',
'    hl.dispatch(hl.dsp.window.pin({ window = selector, action = "off" }))',
'    if window.floating then hl.dispatch(hl.dsp.window.float({ window = selector, action = "off" })) end',
'    drop(window.address)',
'  else',
'    restore(window, sv)',
'  end',
'end',
'',
'-- A lap starts at the current position, visits the other three clockwise,',
'-- then changes type. Only the selected rule placement needs to survive a',
'-- reboot; the next lap starts at that restored position.',
'local edge_lap = { "tile-right", "tile-bottom", "tile-left", "tile-top" }',
'local float_lap = { "top-right", "bottom-right", "bottom-left", "top-left" }',
'',
'local function cycle_notice()',
'  if hl.notification then',
'    hl.notification.create({ text = "Hyprpin: placement could not be saved. Try the shortcut again.", duration = 4000 })',
'  end',
'end',
'',
'local function cycle_position(window, sv)',
'  if sv.special then return "special" end',
'  if sv.edge and not sv.detached then return "tile-" .. sv.edge end',
'  if sv.cycle_slot and sv.cycle_remaining ~= nil then return sv.cycle_slot end',
'  if sv.tiled then return sv.placed_at or "top-right" end',
'  if sv.placed_at == "fill" then return "top-right" end',
'  -- With a very wide float, the right margin can put its center left of',
'  -- the screen center. Keep the selected slot until the user moves it.',
'  local last = sv.placed_rect',
'  local actual = sv.big_prev or observed_float(window)',
'  if not sv.detached and last and last.x == actual.x and last.y == actual.y',
'      and last.w == actual.w and last.h == actual.h then return sv.placed_at end',
'  local m = window.monitor',
'  local uw, uh, ux, uy = usable(m)',
'  local at = sv.big_prev or { x = window.at.x, y = window.at.y, w = window.size.x, h = window.size.y }',
'  local right = at.x + at.w / 2 >= ux + uw / 2',
'  local bottom = at.y + at.h / 2 >= uy + uh / 2',
'  return (bottom and "bottom-" or "top-") .. (right and "right" or "left")',
'end',
'',
'local function cycle_target(current, remaining)',
'  if current == "special" then return "tile-right", 3 end',
'  local edge = edge_side(current) ~= nil',
'  if remaining == 0 then return edge and "top-right" or "tile-right", 3 end',
'  local lap = edge and edge_lap or float_lap',
'  for i, slot in ipairs(lap) do',
'    if slot == current then return lap[i % 4 + 1], remaining - 1 end',
'  end',
'  return "top-right", 3',
'end',
'',
'-- Apply a saved placement without replacing the original home/restore data.',
'local function cycle_place(window, sv, rule)',
'  sv.cycle_edges = sv.cycle_edges or {}',
'  if sv.edge and sv.edge_size then',
'    sv.cycle_edges[(sv.edge == "left" or sv.edge == "right") and "w" or "h"] = sv.edge_size',
'  end',
'  release_edge(sv)',
'  local was_special = window.workspace and window.workspace.special',
'  local source_monitor = window.monitor',
'  local focused = hl.get_active_window()',
'  local keep_focus = focused and focused.address == window.address',
'  sv.big_prev, sv.dock, sv.detached = nil, false, false',
'  sv.fill_monitor, sv.edge_size = nil, nil',
'  sv.edge, sv.special = edge_side(rule.placement), rule.placement == "special"',
'  sv.rule_placement, sv.rule_monitor = rule.placement, rule.monitor',
'  sv.placement, sv.placed_at = rule.placement, rule.placement',
'  local target = (rule.monitor ~= "" and hl.get_monitor(rule.monitor)) or window.monitor',
'  if not target then return end',
'  sv.placed_on = target.name',
'  local selector = "address:" .. window.address',
'  if sv.special then',
'    if window.pinned then hl.dispatch(hl.dsp.window.pin({ window = selector, action = "off" })) end',
'  elseif was_special then',
'    local dest = target.active_workspace',
'    if not dest or dest.special then return end',
'    hl.dispatch(hl.dsp.window.move({ window = selector, workspace = dest.name, follow = false }))',
'    local visible_special = source_monitor and source_monitor.active_special_workspace',
'    if keep_focus and visible_special and visible_special.name == S.special then',
'      source_monitor:set_special_workspace({})',
'    end',
'  end',
'  if sv.edge then',
'    local uw, uh = usable(target)',
'    local sideways = sv.edge == "left" or sv.edge == "right"',
'    sv.edge_size = sv.cycle_edges[sideways and "w" or "h"] or math.floor((sideways and uw or uh) * S.edge_fraction + 0.5)',
'  elseif not sv.special then',
'    local entry = S.sizes[sv.rule_key]',
'    local w, h = geometry(target, rule.placement, entry and entry.floating)',
'    sv.cycle_anchor = { w = w, h = h }',
'  end',
'  place(window, sv, rule)',
'  if sv.special then',
'    local m = window.monitor',
'    local visible = m and m.active_special_workspace',
'    if visible and visible.name == S.special then m:set_special_workspace({}) end',
'  end',
'  if keep_focus and not sv.special then hl.dispatch(hl.dsp.focus({ window = selector })) end',
'  if sv.edge and not sv.detached then',
'    local entry = S.sizes[sv.rule_key] or {}',
'    entry.w, entry.h = sv.expected_w, sv.expected_h',
'    S.sizes[sv.rule_key] = entry',
'    persist_sizes()',
'  elseif not sv.special then',
'    sv.float_observed = nil',
'    -- Save the requested corner geometry separately from the edge size.',
'    local rect = sv.placed_rect',
'    remember_window({ pinned = true, floating = true, monitor = target,',
'      at = { x = rect.x, y = rect.y }, size = { x = rect.w, y = rect.h } }, sv)',
'  end',
'end',
'',
'local function send_cycle(pending, rule, index)',
'  pending.sent_session, pending.sent_revision = S.cycle_session, S.rules_revision',
'  local payload = string.format(\'{"session":"%s","revision":%d,"index":%d,"token":%d,"previous":"%s","next":"%s"}\',',
'    json_escape(S.cycle_session), S.rules_revision, index - 1, pending.token, rule.placement, pending.next)',
'  hl.dispatch(hl.dsp.event("hyprpin-cycle|" .. payload))',
'end',
'',
'local function request_placement(address, destination)',
'  if not S.enabled then return false end',
'  local window = hl.get_window("address:" .. address)',
'  if not window or not window.monitor then return false end',
'  local sv = S.saved[address]',
'  local rule, index',
'  for i, r in ipairs(S.rules) do',
'    if (sv and sv.rule_key == rule_key(r)) or (not sv and r == eligible(window)) then rule, index = r, i break end',
'  end',
'  if not rule then return false end',
'  if not window.pinned and not (sv and (sv.dock or sv.special))',
'      and not (rule.placement == "special" and window.workspace and window.workspace.special) then return false end',
'  if S.cycle_pending then',
'    local pending = S.cycle_pending',
'    if pending.address == address then',
'      if destination == "special" then',
'        pending.park, pending.queued = true, 0',
'      elseif not pending.park and pending.next ~= "special" then',
'        pending.queued = math.min(16, pending.queued + 1)',
'      end',
'    end',
'    return true',
'  end',
'  if destination == "special" and rule.placement == "special"',
'      and window.workspace and window.workspace.special then',
'    local visible = window.monitor.active_special_workspace',
'    if visible and visible.name == S.special then window.monitor:set_special_workspace({}) end',
'    return true',
'  end',
'  local adopt = not sv',
'  if adopt then',
'    local home = window.workspace and not window.workspace.special and window.workspace or window.monitor.active_workspace',
'    if not home then return false end',
'    sv = { monitor = window.monitor.name, workspace_id = home.id, workspace_name = home.name,',
'      floating = window.floating, fullscreen = window.fullscreen, fullscreen_client = window.fullscreen_client,',
'      at = { x = window.at.x, y = window.at.y }, size = { x = window.size.x, y = window.size.y },',
'      rule_key = rule_key(rule), rule_placement = rule.placement, rule_monitor = rule.monitor,',
'      placement = rule.placement, placed_at = rule.placement, placed_on = window.monitor.name,',
'      edge = edge_side(rule.placement), special = rule.placement == "special" }',
'  end',
'  local current = cycle_position(window, sv)',
'  if not sv.cycle_slot then remember_window(window, sv) end',
'  local remaining = sv.cycle_slot == current and sv.cycle_remaining or 3',
'  local next_slot, next_remaining = cycle_target(current, remaining)',
'  if destination == "special" then next_slot, next_remaining = "special", nil end',
'  S.cycle_seq = (S.cycle_seq or 0) % 1000000000 + 1',
'  local token = S.cycle_seq',
'  S.cycle_pending = { token = token, address = address, sv = sv, adopt = adopt,',
'    key = rule_key(rule), previous = rule.placement, next = next_slot, remaining = next_remaining, queued = 0 }',
'  send_cycle(S.cycle_pending, rule, index)',
'  hl.timer(function()',
'    if S.cycle_pending and S.cycle_pending.token == token then',
'      S.cycle_pending = nil',
'      cycle_notice()',
'    end',
'  end, { timeout = 15000, type = "oneshot" })',
'  return true',
'end',
'',
'function S.cycle(address) return request_placement(address) end',
'',
'-- Explicit send only: scratchpad never appears in the SUPER+P lap.',
'function S.send_to_scratchpad(address) return request_placement(address, "special") end',
'',
'function S.cycle_complete(token, success)',
'  local pending = S.cycle_pending',
'  if not pending or pending.token ~= token then return end',
'  S.cycle_pending = nil',
'  local window = hl.get_window("address:" .. pending.address)',
'  if not S.enabled or not window then return end',
'  local rule',
'  for _, r in ipairs(S.rules) do if rule_key(r) == pending.key then rule = r break end end',
'  if not success or not rule or rule.placement ~= pending.next then cycle_notice() return end',
'  local sv = S.saved[pending.address]',
'  if not sv and pending.adopt and (window.pinned or pending.sv.special) then',
'    sv = pending.sv',
'    S.saved[pending.address] = sv',
'  end',
'  if sv ~= pending.sv then return end',
'  cycle_place(window, sv, rule)',
'  sv.cycle_slot, sv.cycle_remaining = pending.next, pending.remaining',
'  if pending.park and pending.next ~= "special" then',
'    S.send_to_scratchpad(pending.address)',
'  elseif pending.next ~= "special" and pending.queued > 0 then',
'    S.cycle(pending.address)',
'    if S.cycle_pending then S.cycle_pending.queued = pending.queued - 1 end',
'  end',
'end',
'',
'-- A failed IPC reply may mean the chunk ran or never reached Hyprland.',
'-- Resolve against a fresh rules snapshot without moving a window twice.',
'function S.cycle_resync(token)',
'  local pending = S.cycle_pending',
'  if not pending or pending.token ~= token then return end',
'  for index, rule in ipairs(S.rules) do',
'    if rule_key(rule) == pending.key then',
'      if rule.placement == pending.next then S.cycle_complete(token, true) return end',
'      local previous = pending.previous or pending.sv.rule_placement',
'      if rule.placement ~= previous then S.cycle_complete(token, false) return end',
'      if pending.sent_session ~= S.cycle_session or pending.sent_revision ~= S.rules_revision then',
'        send_cycle(pending, rule, index)',
'      end',
'      return',
'    end',
'  end',
'  S.cycle_complete(token, false)',
'end',
'',
'-- SUPER+Z on a tracked pop-out (wired in ~/.config/hypr/local.lua): zoom it',
'-- to half the display wide, 80% tall, centered -- and back where it was.',
'function S.toggle_big(address)',
'  local sv = S.saved[address]',
'  local window = hl.get_window("address:" .. address)',
'  if not S.enabled or not sv or not window or sv.special then return end',
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
'  if remember_window(window, sv) then place_edge(window, sv, eligible(window)) end',
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
'-- leaving restores its remembered floating spot, returning re-tiles it.',
'local function dock_here(window, sv, rule)',
'  local m = window.monitor',
'  local dest = m and m.active_workspace',
'  if not dest or dest.special then return false end',
'  local selector = "address:" .. window.address',
'  remember_window(window, sv)',
'  sv.monitor = m.name',
'  sv.workspace_id = dest.id',
'  sv.workspace_name = dest.name',
'  sv.dock = true',
'  sv.big_prev = nil',
'  -- Also release reservations retained by older engine bookkeeping.',
'  release_edge(sv)',
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
'-- SUPER+T: an edge pin detaches to a remembered float and reattaches to its',
'-- stripe. Other pops dock into the workspace, then return to their float.',
'-- False lets the keybind use the stock toggle for an ordinary window.',
'function S.toggle_dock(address)',
'  if not S.enabled then return false end',
'  local window = hl.get_window("address:" .. address)',
'  local sv = window and S.saved[address]',
'  if not sv then return false end',
'  sv.cycle_slot, sv.cycle_remaining = nil, nil',
'  local rule = eligible(window)',
'  if sv.edge then',
'    remember_window(window, sv)',
'    if sv.detached or sv.dock then',
'      -- An occupied edge leaves this pin floating until the user retries.',
'      -- Keep a zoom snapshot intact if no placement change was possible.',
'      if place_edge(window, sv, rule) then',
'        sv.big_prev, sv.dock = nil, false',
'      end',
'    else',
'      release_edge(sv)',
'      sv.big_prev, sv.dock, sv.detached = nil, false, true',
'      place_float(window, sv, rule)',
'    end',
'  elseif sv.dock and sv.tiled then',
'    sv.dock, sv.big_prev = false, nil',
'    place(window, sv, rule)',
'  else',
'    dock_here(window, sv, rule)',
'  end',
'  return true',
'end',
'',
'local function evaluate()',
'  if S.gen ~= gen or not S.enabled then return end',
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
'        -- Moved out of the scratchpad onto an ordinary workspace by hand.',
'        taken = not (window.workspace and window.workspace.special)',
'      else',
'        taken = not window.pinned',
'      end',
'',
'      if taken then',
'        drop(window.address)',
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
'            if (window.floating and not (sv.tiled and sv.big_prev)) or parked then',
'              remember_window(window, sv)',
'              sv.big_prev = nil',
'              hl.dispatch(hl.dsp.window.pin({ window = "address:" .. window.address, action = "off" }))',
'              hl.dispatch(hl.dsp.window.move({ window = "address:" .. window.address, workspace = sv.workspace_name, follow = false }))',
'              hl.dispatch(hl.dsp.window.float({ window = "address:" .. window.address, action = "off" }))',
'              if sv.placed_at and sv.placed_at ~= "fill" then',
'                local tw, th = geometry(home, sv.placed_at, remembered(rule))',
'                place_tiled(window.address, home, sv.placed_at, tw, th)',
'              end',
'              sv.tiled = true',
'            end',
'          elseif sv.tiled then',
'            sv.big_prev = nil',
'            -- Left the docked workspace while tiled: back out to wherever the',
'            -- rule puts it -- corner, edge stripe, or scratchpad.',
'            place(window, sv, rule)',
'            -- For a stay window the dock is only ever a park-here-for-now: once',
'            -- you leave, it reverts to the plain floating pop that stay means,',
'            -- and does not re-tile on return (press SUPER+T again to re-dock).',
'            if rule and rule.stay then sv.dock = false end',
'          end',
'        elseif at_home and not sv.detached and not (rule and rule.stay) then',
'          restore(window, sv)',
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
'    if not seen[address] then drop(address) end',
'  end',
'end',
'',
'-- Sampling catches both drags and resizes. Toggles also capture immediately,',
'-- so a quick move followed by T or Z cannot lose its position. Zoom snapshots',
'-- and workspace layout sizes are excluded by remember_window().',
'local function sample()',
'  if S.gen ~= gen then return end',
'  for address, sv in pairs(S.saved) do',
'    local window = hl.get_window("address:" .. address)',
'    if window and remember_window(window, sv) then place_edge(window, sv, eligible(window)) end',
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
'      if w then release(w, sv) else drop(address) end',
'    end',
'  end',
'end',
'',
'-- A rule edited while its window is popped -- a different corner, edge or',
'-- display -- takes effect now: the window is put back through the normal',
'-- release path and popped again under the new rule, so every transition',
'-- (corner to edge, edge to scratchpad, one display to another) reuses the',
'-- code that already handles it. A window docked into a workspace by',
'-- SUPER+T is left where it is; its next pop-out follows the new rule.',
'if S.enabled then',
'  local by_key = {}',
'  for _, r in ipairs(S.rules) do by_key[rule_key(r)] = by_key[rule_key(r)] or r end',
'  for address, sv in pairs(S.saved) do',
'    local r = sv.rule_key and by_key[sv.rule_key]',
'    if r and sv.rule_placement',
'        and not (S.cycle_pending and S.cycle_pending.address == address)',
'        and (sv.rule_placement ~= r.placement or sv.rule_monitor ~= r.monitor) then',
'      if sv.dock then',
'        sv.rule_placement, sv.rule_monitor = r.placement, r.monitor',
'        sv.placement, sv.placed_at = r.placement, r.placement',
'        sv.edge, sv.edge_size = edge_side(r.placement), nil',
'        sv.special = r.placement == "special" or nil',
'        if r.monitor ~= "" and hl.get_monitor(r.monitor) then sv.placed_on = r.monitor',
'        else sv.placed_on = sv.monitor end',
'      else',
'        local w = hl.get_window("address:" .. address)',
'        if w then',
'          release(w, sv)',
'          w = hl.get_window("address:" .. address)',
'          if w then pop(w, r) end',
'        else',
'          drop(address)',
'        end',
'      end',
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
'-- Close fires before the window leaves get_windows(), so release its',
'-- reservation directly instead of waiting for evaluate() to find it gone.',
'-- Disabling the gap rule schedules Hyprland\'s layout refresh immediately.',
'S.close_sub = hl.on("window.close", function(window)',
'  if S.gen ~= gen then return end',
'  if window and window.address then',
'    local sv = S.saved[window.address]',
'    if sv then remember_window(window, sv) end',
'    drop(window.address)',
'  end',
'end)',
'',
'S.sub = hl.on("workspace.active", function()',
'  if S.gen ~= gen then return end',
'  -- The monitor\'s active_workspace is not settled while the event fires, and',
'  -- the delay coalesces a burst of switches into one evaluation.',
'  hl.timer(evaluate, { timeout = 60, type = "oneshot" })',
'end)',
'',
cycleReply ? 'S.cycle_complete(' + cycleReply.token + ', ' + (cycleReply.success ? 'true' : 'false') + ')' : '',
cycleResync !== null ? 'S.cycle_resync(' + cycleResync + ')' : ''
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
        property int code: -1
        property bool streamDone: false
        property string payload: ""
        stdout: StdioCollector {
            onStreamFinished: {
                applyProc.payload = String(text).slice(0, 1024)
                applyProc.streamDone = true
                applyProc.finish()
            }
        }
        onExited: function(exitCode) { code = exitCode; finish() }
        function finish() {
            if (code < 0 || !streamDone)
                return
            var exitCode = code
            var reply = payload.trim()
            code = -1; streamDone = false; payload = ""
            root.finishApply(exitCode, reply)
        }
    }

    function finishApply(exitCode, reply) {
        var receipt = applyReceipt
        applyReceipt = null
        if (exitCode === 0 && reply === "ok") {
            applyFailures = 0
            return
        }
        console.warn("hyprpin: Hyprland apply failed (exit " + exitCode + "):", reply.slice(0, 400))
        if (++applyFailures <= 2) {
            // A lost reply does not tell us whether Hyprland executed it.
            // Pending tokens make replay safe even if the window already moved.
            if (!cycleReply && receipt && receipt.reply)
                cycleReply = receipt.reply
            if (cycleResync === null && receipt && receipt.resync !== null)
                cycleResync = receipt.resync
            settle.restart()
        } else {
            // End this retry budget. A later keypress/settings change can
            // start another attempt; no stale receipt blocks the writer.
            applyFailures = 0
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
        applyReceipt = { reply: cycleReply, resync: cycleResync }
        applyProc.command = ["/usr/bin/hyprctl", "eval", root.lua()]
        cycleReply = null
        cycleResync = null
        applyProc.code = -1; applyProc.streamDone = false; applyProc.payload = ""
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
            else if (event && event.name === "custom" && typeof event.data === "string"
                    && event.data.length <= 1024 && event.data.indexOf("hyprpin-cycle|") === 0)
                root.handleCycle(event.data.slice(14))
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
