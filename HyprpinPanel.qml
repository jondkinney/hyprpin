import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon plus its drop-down: pick which windows follow you across workspaces,
// and where each one goes. Rules are written to a small state file that
// Service.qml watches and turns into live Hyprland behaviour.
Panel {
    id: root
    moduleName: "io.github.jondkinney.hyprpin"
    ipcTarget: "io.github.jondkinney.hyprpin"

    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property color dim: Qt.darker(foreground, 1.55)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    // Hex form of the foreground, for the <font color> in the StyledText legend.
    readonly property string fgHex: {
        var c = root.foreground
        function h(x) { var v = Math.round(x * 255).toString(16); return v.length < 2 ? "0" + v : v }
        return "#" + h(c.r) + h(c.g) + h(c.b)
    }

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
    readonly property string statePath: stateDir + "/hyprpin.json"

    // Reads and writes of the replaceable state file go through statefile.py:
    // a bounded O_NOFOLLOW descriptor read, and an exclusive-staging atomic
    // write. The shell never materializes the file itself.
    readonly property string helperPath: {
        var url = Qt.resolvedUrl("statefile.py").toString()
        return url.indexOf("file://") === 0 ? url.slice(7) : url
    }

    readonly property var hyprctlEnv: ({
        HYPRLAND_INSTANCE_SIGNATURE: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
        XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR") || "",
        HOME: Quickshell.env("HOME") || ""
    })

    // The bar sizes each widget slot from its item's implicit size
    // (Bar.qml: activeItem.implicitWidth), and Panel is a bare Item whose
    // implicit size stays 0 -- without this binding the icon renders into a
    // zero-width slot and never appears. Verified the hard way: hot plugin
    // reloads can keep serving the previously compiled component, so removing
    // this looked harmless until the next full shell restart made it not be.
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    property var rules: []
    property var windows: []
    property var monitorNames: []

    // The global switch. Off stops the service matching anything and hands
    // every pop-out back; the rules stay exactly as they are, so on is a
    // resume, not a rebuild. Lives in the state file next to the rules so a
    // hand edit and the service see the same thing. Missing key reads as on.
    property bool enabled: true

    // Window titles and classes are set by the applications themselves, so they
    // are never trusted here: rendered as plain text, length-capped, and with
    // control, C1 and bidi characters replaced, since those can reorder what is
    // on screen and make one window's row read as another's.
    function displayText(value, limit) {
        var s = typeof value === "string" ? value : ""
        if (s.length > limit)
            s = s.slice(0, limit)
        var out = ""
        for (var i = 0; i < s.length; i++) {
            var c = s.charCodeAt(i)
            var unsafe = c < 32 || c === 127 || (c >= 128 && c <= 159)
                || (c >= 8234 && c <= 8238) || (c >= 8294 && c <= 8297)
            out += unsafe ? "?" : s.charAt(i)
        }
        return out
    }

    // --------------------------------------------------------------- rules io

    function parseState(raw) {
        var none = { enabled: true, rules: [] }
        if (typeof raw !== "string" || raw.length === 0 || raw.length > 262144)
            return none
        var parsed
        try {
            parsed = JSON.parse(raw)
        } catch (e) {
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
            if (!r || typeof r !== "object" || typeof r["class"] !== "string")
                continue
            var placement = typeof r.placement === "string" ? r.placement.slice(0, 32) : "fill"
            // Older files carried a `tile` flag on top of a corner; that mode
            // is gone and the right edge is its nearest replacement.
            if (r.tile === true && placement.indexOf("tile-") !== 0)
                placement = "tile-right"
            out.push({
                "class": r["class"].slice(0, 256),
                title: typeof r.title === "string" ? r.title.slice(0, 256) : "",
                monitor: typeof r.monitor === "string" ? r.monitor.slice(0, 64) : "",
                placement: placement,
                label: typeof r.label === "string" ? r.label.slice(0, 128) : "",
                stay: r.stay === true
            })
        }
        return { enabled: enabled, rules: out }
    }

    // Pointed at the state directory, the FileView never loads content (a
    // directory load fails by design); only its change watcher is used. All
    // writers publish by atomic rename, which is a directory-entry change.
    FileView {
        path: root.stateDir
        watchChanges: true
        printErrors: false
        onFileChanged: rereadSettle.restart()
    }

    Timer {
        id: rereadSettle
        interval: 250
        onTriggered: rulesReadProc.start()
    }

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
                rulesReadProc.settle()
            }
        }
        onExited: function (exitCode) { code = exitCode; settle() }
        function start() {
            if (running) { rerun = true; return }
            code = -1; streamDone = false; payload = ""
            running = true
        }
        function settle() {
            if (code < 0 || !streamDone)
                return
            if (code === 0 || code === 3) {
                var state = code === 0 ? root.parseState(payload) : { enabled: true, rules: [] }
                root.enabled = state.enabled
                root.rules = state.rules
            } else {
                console.warn("hyprpin: rules read refused (exit " + code + ")")
            }
            payload = ""
            if (rerun) { rerun = false; start() }
        }
    }

    Process {
        id: writeProc
        command: ["/usr/bin/python3", "-I", root.helperPath, "write", root.statePath, "262144"]
        clearEnvironment: true
        stdinEnabled: true
        property string pending: ""
        onStarted: {
            writeProc.write(pending)
            pending = ""
            stdinEnabled = false
        }
        property string queued: ""
        onExited: function (exitCode) {
            stdinEnabled = true
            if (exitCode !== 0)
                console.warn("hyprpin: rules write failed (exit " + exitCode + ")")
            if (queued.length) {
                pending = queued
                queued = ""
                running = true
            }
        }
    }

    Timer {
        interval: 10000
        repeat: true
        running: rulesReadProc.running || writeProc.running
        onTriggered: {
            if (rulesReadProc.running) rulesReadProc.signal(9)
            if (writeProc.running) writeProc.signal(9)
        }
    }

    function save() {
        var body = JSON.stringify({ version: 1, enabled: root.enabled, rules: root.rules }, null, 2) + "\n"
        // A save while the previous one is in flight queues behind it; only
        // the newest queued body matters, since each save carries all rules.
        if (writeProc.running) {
            writeProc.queued = body
            return
        }
        writeProc.pending = body
        writeProc.running = true
    }

    // Flipped optimistically so the icon and the switch answer at once; the
    // file write that follows is what the service actually acts on, and the
    // re-read after it lands settles the value either way.
    function setEnabled(on) {
        root.enabled = on === true
        save()
    }

    // The shell's Dropdown caps its popup at eight rows and exposes no knob
    // for it; the placement list has ten, and a list that scrolls hides the
    // shape of the choice (edges as one lap of the display, corners as
    // another). The popup is a private child of the control, so it is
    // located by walking the control's object tree once and its height
    // rebound to fit every option. If the shell's Dropdown ever changes shape
    // the lookup fails soft: nothing is touched and the list scrolls as
    // before, with a note in the log.
    function findPopup(obj, depth) {
        if (!obj || depth > 6)
            return null
        var list = obj.data
        if (!list)
            return null
        for (var i = 0; i < list.length; i++) {
            var o = list[i]
            if (!o)
                continue
            // The option popup specifically: a tooltip parked inside the
            // control is a popup too, so match on the option list it holds.
            if (typeof o.open === "function" && "opened" in o && o.contentItem
                    && typeof o.contentItem.selectCurrent === "function")
                return o
            var found = findPopup(o, depth + 1)
            if (found)
                return found
        }
        return null
    }

    function fitDropdownPopup(dd) {
        var popup = findPopup(dd, 0)
        if (!popup) {
            console.warn("hyprpin: placement dropdown popup not found; it will scroll")
            return
        }
        popup.implicitHeight = Qt.binding(function () {
            var n = dd.options.length
            return n * dd.popupRowHeight + Math.max(0, n - 1) * Style.spacing.labelGap + Style.spacing.xxs
        })
    }

    // ------------------------------------------------------------- derivation

    function luaPatternEscape(value) {
        return String(value).replace(/[\^\$\(\)%\.\[\]\*\+\-\?]/g, function (m) { return "%" + m })
    }

    // Turn the window you picked into a rule that still matches the next one
    // like it. Chrome names an --app window after its URL, and the path segment
    // changes per meeting or document -- a Meet call is
    // "chrome-meet.google.com__<code>-Default" -- so those anchor on the host
    // and let the rest vary. Everything else pins to class and title, which is
    // what separates a Zoom call window ("Meeting") from the Workplace window,
    // its toolbars and its chat panels, all of which share the class "Zoom".
    function deriveRule(win) {
        var cls = String(win["class"] || "")
        var title = String(win.title || "")
        var app = cls.match(/^chrome-([^_]+)__(.*)$/)
        if (app) {
            var host = "^chrome%-" + luaPatternEscape(app[1]) + "__"
            // A bare site is "<host>__-Default"; anything else carries a path,
            // which is what tells a call apart from the landing page.
            return {
                "class": app[2].charAt(0) === "-" ? host : host + "[^%-]",
                title: "",
                label: app[1]
            }
        }
        return {
            "class": "^" + luaPatternEscape(cls) + "$",
            title: title.length ? "^" + luaPatternEscape(title) + "$" : "",
            label: title.length ? cls + " - " + title : cls
        }
    }

    function addRule(win) {
        var derived = deriveRule(win)
        for (var i = 0; i < root.rules.length; i++) {
            if (root.rules[i]["class"] === derived["class"]
                    && root.rules[i].title === derived.title)
                return
        }
        // Default to filling the last display listed when there is a spare one
        // -- the case this exists for -- and a corner otherwise.
        var hasSpare = root.monitorNames.length > 1
        root.rules = root.rules.concat([{
            "class": derived["class"],
            title: derived.title,
            monitor: hasSpare ? root.monitorNames[root.monitorNames.length - 1] : "",
            placement: hasSpare ? "fill" : "bottom-right",
            label: derived.label,
            // Stay on by default -- a window that quietly snapped back the moment
            // you returned to its workspace surprised more than it helped.
            stay: true
        }])
        save()
    }

    function setFields(index, patch) {
        if (index < 0 || index >= root.rules.length)
            return
        var next = []
        for (var i = 0; i < root.rules.length; i++) {
            var r = root.rules[i]
            var copy = { "class": r["class"], title: r.title, monitor: r.monitor,
                         placement: r.placement, label: r.label,
                         stay: r.stay === true }
            if (i === index)
                for (var k in patch)
                    copy[k] = patch[k]
            next.push(copy)
        }
        root.rules = next
        save()
    }

    function setField(index, key, value) {
        var patch = {}
        patch[key] = value
        setFields(index, patch)
    }

    function removeRule(index) {
        var next = []
        for (var i = 0; i < root.rules.length; i++) {
            if (i !== index)
                next.push(root.rules[i])
        }
        root.rules = next
        save()
    }

    function ruleFor(win) {
        var derived = deriveRule(win)
        for (var i = 0; i < root.rules.length; i++) {
            if (root.rules[i]["class"] === derived["class"] && root.rules[i].title === derived.title)
                return i
        }
        return -1
    }

    // ----------------------------------------------------------- live sources

    function refreshWindows() {
        Hyprland.refreshToplevels()
        var model = Hyprland.toplevels
        var list = model && model.values ? model.values : []
        var out = []
        for (var i = 0; i < list.length && out.length < 100; i++) {
            var ipc = list[i] ? list[i].lastIpcObject : null
            if (!ipc || typeof ipc["class"] !== "string" || !ipc["class"].length)
                continue
            out.push({
                "class": ipc["class"].slice(0, 200),
                title: typeof ipc.title === "string" ? ipc.title.slice(0, 200) : "",
                workspace: ipc.workspace && ipc.workspace.name ? String(ipc.workspace.name).slice(0, 40) : ""
            })
        }
        out.sort(function (a, b) {
            var byClass = a["class"].localeCompare(b["class"])
            return byClass !== 0 ? byClass : a.title.localeCompare(b.title)
        })
        root.windows = out
    }

    Process {
        id: monitorsProc
        command: ["/usr/bin/hyprctl", "monitors", "-j"]
        clearEnvironment: true
        environment: root.hyprctlEnv
        stdout: StdioCollector {
            onStreamFinished: {
                var names = []
                try {
                    var raw = String(text)
                    if (raw.length > 262144)
                        throw new Error("oversized reply")
                    var arr = JSON.parse(raw)
                    if (Array.isArray(arr)) {
                        for (var i = 0; i < arr.length && names.length < 16; i++) {
                            var n = arr[i] ? arr[i].name : null
                            if (typeof n === "string" && /^[A-Za-z0-9._:-]{1,64}$/.test(n))
                                names.push(n)
                        }
                    }
                } catch (e) {
                    // Leave the list as it was; the dropdown still offers "Same display".
                }
                root.monitorNames = names
            }
        }
    }

    Timer {
        interval: 10000
        repeat: true
        running: monitorsProc.running
        onTriggered: monitorsProc.signal(9)
    }

    readonly property var monitorOptions: {
        var opts = [{ value: "", label: "Same display" }]
        for (var i = 0; i < monitorNames.length; i++)
            opts.push({ value: monitorNames[i], label: monitorNames[i] })
        return opts
    }

    readonly property var availableWindows: {
        var out = []
        for (var i = 0; i < windows.length; i++)
            if (ruleFor(windows[i]) < 0)
                out.push(windows[i])
        return out
    }

    // Tiled edges clockwise from the top, then floating corners clockwise
    // from the top left, so each group reads as a lap around the display.
    readonly property var placementOptions: [
        { value: "fill", label: "Fill it" },
        { value: "tile-top", label: "Tiled top" },
        { value: "tile-right", label: "Tiled right" },
        { value: "tile-bottom", label: "Tiled bottom" },
        { value: "tile-left", label: "Tiled left" },
        { value: "top-left", label: "Floating top left" },
        { value: "top-right", label: "Floating top right" },
        { value: "bottom-right", label: "Floating bottom right" },
        { value: "bottom-left", label: "Floating bottom left" },
        { value: "special", label: "Scratchpad" }
    ]

    onOpenedChanged: {
        if (opened) {
            refreshWindows()
            refreshSettle.restart()
            monitorsProc.running = true
        }
    }

    // refreshToplevels() is an asynchronous round trip, so the snapshot taken
    // above can miss a window opened moments before. One late pass covers it.
    Timer {
        id: refreshSettle
        interval: 400
        onTriggered: if (root.opened) root.refreshWindows()
    }

    Component.onCompleted: {
        rulesReadProc.start()
        monitorsProc.running = true
    }

    // --------------------------------------------------------------------- ui

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        // The button's own text slot renders in the bar's icon font; a
        // hand-rolled Text has no way to know about that and just draws tofu.
        text: ""
        // Two dim states, kept distinct: the icon goes dark when there is
        // nothing to follow you, and translucent as well when the plugin is
        // switched off -- so an off plugin with rules still reads as "off",
        // not as "empty".
        foreground: root.enabled && root.rules.length > 0
            ? root.barForeground : Qt.darker(root.barForeground, 1.55)
        dimmed: !root.enabled
        tooltipText: (!root.enabled
            ? "Hyprpin is off"
            : root.rules.length === 0
                ? "No windows set to follow you"
                : root.rules.length + (root.rules.length === 1 ? " window follows you" : " windows follow you"))
            + "\nClick to choose, right-click to turn " + (root.enabled ? "off" : "on")
        // Right-click is the power user's switch: flips the whole plugin
        // without opening anything, the way the audio widget mutes.
        onPressed: function (b) {
            if (b === Qt.RightButton) root.setEnabled(!root.enabled)
            else root.toggle()
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        contentWidth: panel.fittedContentWidth(Style.space(420))
        // Up to 80% of the screen tall before it needs to scroll; the old fixed
        // cap cut the list off on tall monitors that had room to spare.
        contentHeight: panel.fittedContentHeight(content.implicitHeight, Math.round(panel.screenH * 0.8))

        // One viewport for the whole panel body. The card caps its height at
        // whatever fits the screen, and anything past that must scroll --
        // otherwise the column keeps painting straight through the border
        // (which it did, twice, before this).
        Flickable {
            id: scroller
            anchors.fill: parent
            contentWidth: width
            contentHeight: content.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            ColumnLayout {
                id: content
                width: scroller.width
                spacing: Style.space(6)

                // Title row: the panel's name, and the global on/off switch on
                // its trailing edge -- the obvious place to find out the whole
                // thing can be switched off (right-clicking the bar icon does
                // the same without opening the panel).
                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Style.spacing.xs
                    spacing: Style.spacing.xl

                    OpticalGlyph {
                        Layout.preferredWidth: Math.round(Style.space(24))
                        Layout.preferredHeight: Math.round(Style.space(24))
                        text: ""
                        fontFamily: root.fontFamily
                        fontSize: Math.round(Style.font.heading * 1.25)
                        color: root.enabled ? Color.accent : root.dim
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Hyprpin"
                        textFormat: Text.PlainText
                        color: Color.popups.text
                        font.family: root.fontFamily
                        font.pixelSize: Math.round(Style.font.heading * 1.25)
                        font.weight: Font.DemiBold
                        // Leave room for font overshoot at the clipped viewport's top.
                        topPadding: Math.ceil(font.pixelSize * 0.15)
                        elide: Text.ElideRight
                    }

                    ToggleSwitch {
                        id: powerSwitch
                        checked: root.enabled
                        foreground: root.foreground
                        Layout.alignment: Qt.AlignVCenter
                        onToggled: root.setEnabled(!root.enabled)

                        PanelToolTip {
                            visible: powerSwitch.containsMouse
                            delay: 350
                            text: root.enabled
                                ? "Turn off: every pop-out goes back where it came from and nothing follows you until you turn it on again. Rules are kept."
                                : "Turn on: windows with a rule follow you again."
                            fontFamily: root.fontFamily
                        }
                    }
                }

                Text {
                    visible: !root.enabled
                    Layout.fillWidth: true
                    text: "Off -- nothing follows you right now. Your rules are kept; switch back on to resume."
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: "Switch away from one of these windows' workspaces and it moves to the display and spot you pick, staying in view while you work elsewhere."
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                }

                // Toggle key -- a small definition list, explained once here so the
                // per-rule rows can stay compact. The toggle name is drawn in the
                // foreground colour, its meaning dimmed.
                GridLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(2)
                    columns: 2
                    columnSpacing: Style.space(10)
                    rowSpacing: Style.space(4)

                    Text {
                        Layout.alignment: Qt.AlignTop
                        text: "Stay pinned"
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Keep pinned, even on the originating workspace. If set to off - the pin snaps back into tiling on the originating workspace."
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        Layout.alignment: Qt.AlignTop
                        text: "Tiled"
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Placements that reserve one edge of the display for the window. Everything else tiles beside it, on every workspace; resize it and the tiles follow."
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        Layout.alignment: Qt.AlignTop
                        text: "Scratchpad"
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "A placement that hides the window in the scratchpad instead of showing it. SUPER+S summons it on any display."
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }
                }

                PanelSeparator {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(4)
                }

                Text {
                    visible: root.rules.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(2)
                    text: "Nothing set yet -- pick a window from the list below to add one."
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.rules

                    delegate: ColumnLayout {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.topMargin: Style.space(8)
                        spacing: Style.space(5)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(8)

                            Text {
                                Layout.fillWidth: true
                                text: root.displayText(modelData.label || modelData["class"], 120)
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                elide: Text.ElideRight
                            }

                            Button {
                                text: "Remove"
                                fontFamily: root.fontFamily
                                foreground: root.foreground
                                onClicked: root.removeRule(index)
                            }
                        }

                        // Editable match patterns (Lua patterns). Class is required;
                        // an empty title matches any title.
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: Style.space(8)
                            rowSpacing: Style.space(4)

                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: "Class"
                                textFormat: Text.PlainText
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                            TextField {
                                Layout.fillWidth: true
                                text: modelData["class"]
                                placeholderText: "Lua pattern, e.g. ^Zoom$"
                                foreground: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                onEditingFinished: {
                                    if (text !== modelData["class"])
                                        root.setField(index, "class", text)
                                }
                            }

                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: "Title"
                                textFormat: Text.PlainText
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                            TextField {
                                Layout.fillWidth: true
                                text: modelData.title
                                placeholderText: "any title"
                                foreground: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                onEditingFinished: {
                                    if (text !== modelData.title)
                                        root.setField(index, "title", text)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(8)

                            Dropdown {
                                Layout.fillWidth: true
                                label: "Display"
                                options: root.monitorOptions
                                // A special workspace follows whichever monitor you
                                // toggle it on, so the display is moot for Scratchpad.
                                readonly property bool moot: modelData.placement === "special"
                                enabled: !moot
                                opacity: moot ? 0.4 : 1
                                value: modelData.monitor
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onChanged: function (v) { root.setField(index, "monitor", v) }
                            }

                            Dropdown {
                                id: placementDropdown
                                Layout.fillWidth: true
                                label: "Placement"
                                options: root.placementOptions
                                value: modelData.placement
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onChanged: function (v) { root.setField(index, "placement", v) }
                                Component.onCompleted: root.fitDropdownPopup(placementDropdown)

                                property bool hoverNow: false
                                onHovered: function (on) { hoverNow = on }

                                PanelToolTip {
                                    visible: parent.hoverNow && !parent.popupOpen
                                    delay: 350
                                    text: "Tiled: reserves that edge on every workspace. SUPER+T switches between the edge and a remembered floating position; move or resize the float to set it.\nScratchpad: hides it in the scratchpad instead; SUPER+S brings it up."
                                    fontFamily: root.fontFamily
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(8)

                            Item { Layout.fillWidth: true }

                            Text {
                                text: "Stay pinned"
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }

                            ToggleSwitch {
                                checked: modelData.stay === true
                                foreground: root.foreground
                                onToggled: root.setField(index, "stay", !(modelData.stay === true))
                            }
                        }

                        PanelSeparator {
                            Layout.fillWidth: true
                            Layout.topMargin: Style.space(8)
                        }
                    }
                }

                PanelSectionHeader {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(8)
                    text: "Open windows"
                    fontFamily: root.fontFamily
                    foreground: root.foreground
                }

                Repeater {
                    model: root.availableWindows

                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.topMargin: Style.space(5)
                        spacing: Style.space(8)

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Text {
                                Layout.fillWidth: true
                                text: root.displayText(modelData.title || modelData["class"], 120)
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                elide: Text.ElideRight
                            }

                            Text {
                                Layout.fillWidth: true
                                text: root.displayText(modelData["class"], 90)
                                    + (modelData.workspace ? "   workspace " + root.displayText(modelData.workspace, 40) : "")
                                textFormat: Text.PlainText
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                elide: Text.ElideRight
                            }
                        }

                        Button {
                            text: "Add"
                            fontFamily: root.fontFamily
                            foreground: root.foreground
                            onClicked: root.addRule(modelData)
                        }
                    }
                }
            }
        }
    }
}
