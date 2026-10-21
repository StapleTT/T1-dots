import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Notifications
import Quickshell.Services.Pam
import Quickshell.Services.Pipewire
import Quickshell.Services.Polkit
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import Quickshell.Widgets

ShellRoot {
    id: root

    // Black rounded "island" with a shadow; children are laid out in a row.
    component Pill: Rectangle {
        default property alias content: row.data
        property alias spacing: row.spacing
        y: 10
        height: 34
        width: row.implicitWidth + 28
        radius: height / 2
        color: "black"

        Behavior on width { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.5 } }

        layer.enabled: true
        layer.effect: Shadow {}

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 12
        }
    }

    component Shadow: MultiEffect {
        shadowEnabled: true
        shadowColor: "#b0000000"
        shadowBlur: 0.8
        shadowVerticalOffset: 3
    }

    component Label: Text {
        color: "white"
        font { family: "Rubik"; pixelSize: 13 }
    }

    component Icon: Text {
        color: "white"
        font { family: "Framework7 Icons"; pixelSize: 17 } // iOS / SF Symbols style, MIT; text is the icon name
    }

    // Icon that reacts to clicks
    component IconButton: Icon {
        signal clicked()
        property bool closesPanel: true // set false on buttons that open a dropdown themselves
        opacity: area.containsMouse ? 0.7 : 1
        MouseArea {
            id: area
            // At least 28px square around the icon, so small icons (the tray chevron) are easy to hit
            anchors.centerIn: parent
            width: Math.max(parent.width + 8, 28)
            height: Math.max(parent.height + 8, 28)
            hoverEnabled: true
            onClicked: {
                if (parent.closesPanel) root.panel = "";
                parent.clicked();
            }
        }
    }

    // Row in a dropdown panel
    component MenuItem: Rectangle {
        required property string icon
        required property string label
        property string iconSource: "" // SVG instead of the font icon
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: 34
        radius: 10
        color: itemArea.containsMouse ? "#22ffffff" : "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            spacing: 10
            Icon { text: parent.parent.icon; visible: parent.parent.iconSource === ""; Layout.preferredWidth: 20; horizontalAlignment: Text.AlignHCenter }
            Image { source: parent.parent.iconSource; sourceSize: Qt.size(17, 17); visible: parent.parent.iconSource !== ""; Layout.preferredWidth: 20; fillMode: Image.Pad }
            Label { text: parent.parent.label; Layout.fillWidth: true }
        }
        MouseArea {
            id: itemArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: parent.clicked()
        }
    }

    function run(cmd) {
        Quickshell.execDetached(["sh", "-c", cmd]);
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // ---- Network status, sampled every 2 s ----

    readonly property int interval: 2000
    property bool wifiOn: false
    property string wifiName: ""
    property int wifiSignal: 0
    property bool ethernet: false

    Process {
        id: stats
        command: ["sh", "-c", `
            echo "radio $(nmcli radio wifi)"
            echo "wifi $(nmcli -t -f ACTIVE,SIGNAL,SSID dev wifi list --rescan no | grep -m1 '^yes')"
            echo "eth $(nmcli -t -f TYPE,STATE dev | grep -c '^ethernet:connected$')"`]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = {};
                for (const line of text.trim().split("\n")) {
                    const i = line.indexOf(" ");
                    f[line.slice(0, i)] = line.slice(i + 1).trim();
                }

                // wifi line is "yes:<signal>:<ssid>" (ssid may contain ':') or empty
                root.wifiOn = f.radio === "enabled";
                const w = f.wifi ? f.wifi.split(":") : [];
                root.wifiSignal = w.length > 2 ? parseInt(w[1]) : 0;
                root.wifiName = w.length > 2 ? w.slice(2).join(":") : "";
                root.ethernet = parseInt(f.eth) > 0;
            }
        }
    }

    Timer {
        interval: root.interval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: stats.running = true
    }

    // Bluetooth (BlueZ): paired devices, connected ones first; the tray shows an icon only while one is connected
    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property var btDevices: Bluetooth.devices.values.filter(d => d.paired).sort((a, b) => b.connected - a.connected)
    readonly property bool btConnected: btDevices.some(d => d.connected)
    // Framework7 has no Bluetooth glyph, so "" means the custom icons/bluetooth.svg
    function btIcon(device) {
        const icon = device.icon;
        return icon.startsWith("audio") ? "headphones" : icon === "input-gaming" ? "gamecontroller_fill"
            : icon === "input-keyboard" ? "keyboard" : icon === "phone" ? "device_phone_portrait" : "";
    }

    // Workspace dot colours: app ID -> most vivid colour of its icon (saturation x brightness), ignoring transparent pixels
    property var appColors: ({})
    function vividColor(colors) {
        let best = Qt.color("white"), score = 0.15; // greyscale icons (Zen) fall back to white
        for (const c of colors) {
            const sc = c.hsvSaturation * c.hsvValue;
            if (c.a > 0.5 && sc > score) { best = c; score = sc; }
        }
        return best;
    }

    // Icon file for an app ID, for ColorQuantizer (it can't read image://icon URLs). Theme lookups run once per
    // icon name in the background; "" until found. Prefers scalable, else the largest size.
    property var iconFiles: ({})
    Component {
        id: iconFinder
        Process {
            property string name
            running: true
            command: ["sh", "-c", 'find ~/.local/share/icons /usr/share/icons/hicolor /usr/share/icons/Adwaita /usr/share/pixmaps \\( -name "$1.svg" -o -name "$1.png" \\) 2>/dev/null | sort -V | tail -1', "_", name]
            stdout: StdioCollector {
                onStreamFinished: root.iconFiles = Object.assign({}, root.iconFiles, { [name]: text.trim() })
            }
        }
    }
    function iconFile(appId) {
        const entry = DesktopEntries.heuristicLookup(appId) ?? DesktopEntries.applications.values.find(e => e.startupClass === appId);
        const icon = entry?.icon || appId;
        if (icon.startsWith("/")) return icon;
        if (!(icon in iconFiles)) {
            iconFiles[icon] = ""; // pending; not reassigned, so no binding loop
            iconFinder.createObject(root, { name: icon });
        }
        return iconFiles[icon];
    }

    readonly property string wifiIcon: !wifiOn ? "wifi_slash" : wifiName === "" ? "wifi_exclamationmark" : "wifi"

    // ---- Media: the playing player, else the first one ----

    readonly property var player: Mpris.players.values.find(p => p.isPlaying) ?? Mpris.players.values[0] ?? null
    onPlayerChanged: if (!player) mediaOpen = false

    // Media widget: the title island morphs into a player when the music circle is clicked
    property bool mediaOpen: false
    onMediaOpenChanged: if (mediaOpen) { panel = ""; launcherOpen = false; }

    // ---- OSD: the title island briefly shows volume or brightness when they change ----

    property string osdKind: "" // "volume", "brightness" or ""
    function showOsd(kind) { osdKind = kind; osdTimer.restart(); }
    Timer { id: osdTimer; interval: 1500; onTriggered: root.osdKind = "" }

    // Volume: any change to the default output (media keys, apps, other mixers)
    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker { objects: [root.sink] }
    readonly property real volume: sink?.audio?.volume ?? 0
    readonly property bool muted: sink?.audio?.muted ?? false
    readonly property string volumeIcon: muted || volume === 0 ? "speaker_slash_fill"
        : volume < 0.34 ? "speaker_1_fill" : volume < 0.67 ? "speaker_2_fill" : "speaker_3_fill"
    // Outputs for the audio panel: hardware sinks, not app streams
    readonly property var sinks: Pipewire.nodes.values.filter(n => n.isSink && !n.isStream && n.audio)
    property bool osdArmed: false // skip the change when the sink first binds at startup
    Timer { interval: 2000; running: true; onTriggered: root.osdArmed = true }
    Connections {
        target: root.sink?.audio ?? null
        function onVolumeChanged() { if (root.osdArmed) root.showOsd("volume"); }
        function onMutedChanged() { if (root.osdArmed) root.showOsd("volume"); }
    }

    // Brightness: the monitor's own setting over DDC/CI (no backlight on this desktop).
    // Kept here so the OSD updates instantly; ddcutil is slow, so writes are coalesced.
    property int brightness: -1 // 0-100, -1 until read
    Process {
        running: true
        command: ["ddcutil", "getvcp", "10", "--brief"]
        stdout: StdioCollector {
            onStreamFinished: { const m = text.match(/C (\d+) /); if (m) root.brightness = +m[1]; }
        }
    }
    Timer {
        id: ddcTimer
        interval: 150
        // The monitor sometimes rejects a write (DDCRC_VERIFY), so retry a few times
        onTriggered: Quickshell.execDetached(["sh", "-c", 'for i in 1 2 3; do ddcutil setvcp 10 "$1" && exit; sleep 0.2; done', "_", String(root.brightness)])
    }
    function stepBrightness(delta) {
        if (brightness < 0) return;
        brightness = Math.max(0, Math.min(100, brightness + delta));
        ddcTimer.restart();
        showOsd("brightness");
    }
    IpcHandler {
        target: "osd"
        function brightnessUp(): void { root.stepBrightness(5); }
        function brightnessDown(): void { root.stepBrightness(-5); }
    }

    // ---- Lock screen: wallpaper, date and time above centre, password pill near the bottom ----
    // Locked from the power menu or `qs ipc call lock lock` (hypridle's lock_cmd).
    // If Quickshell dies while locked, Hyprland's misc.allow_session_lock_restore lets a restarted qs lock again.

    property bool locked: false
    property bool keepAwake: false // coffee cup in the power menu; idle inhibitor on every bar
    // Kept in a state file so it survives Quickshell restarts
    FileView {
        id: keepAwakeFile
        path: `${Quickshell.env("HOME")}/.local/state/quickshell/keep-awake`
        printErrors: false // missing until first toggled
        onLoaded: root.keepAwake = text().trim() === "1"
    }
    onKeepAwakeChanged: keepAwakeFile.setText(keepAwake ? "1" : "0")
    IpcHandler {
        target: "keepAwake"
        function set(on: bool): void { root.keepAwake = on; }
        function toggle(): void { root.keepAwake = !root.keepAwake; }
        function get(): bool { return root.keepAwake; }
    }
    property string lockPassword: "" // shared by the lock surfaces on every monitor
    property string lockError: ""
    property bool authenticating: false
    property string wallpaper: ""
    signal lockFailed()

    onLockedChanged: {
        lockPassword = "";
        lockError = "";
        if (locked) { panel = ""; launcherOpen = false; mediaOpen = false; overviewOpen = false; }
    }

    IpcHandler {
        target: "lock"
        function lock(): void { root.locked = true; }
    }

    // Use the wallpaper from hyprpaper.conf so the two never drift apart
    FileView {
        path: `${Quickshell.env("HOME")}/.config/hypr/hyprpaper.conf`
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const m = text().match(/^\s*path\s*=\s*(.+?)\s*$/m);
            root.wallpaper = m ? m[1].replace(/^~/, Quickshell.env("HOME")) : "";
        }
    }

    function tryUnlock() {
        if (authenticating || lockPassword === "") return;
        authenticating = true;
        lockError = "";
        if (!pam.start()) {
            authenticating = false;
            lockError = "Couldn't start authentication";
        }
    }

    PamContext {
        id: pam
        config: "login"
        onResponseRequiredChanged: if (responseRequired) respond(root.lockPassword)
        onCompleted: result => {
            root.authenticating = false;
            root.lockPassword = "";
            if (result === PamResult.Success) {
                root.locked = false;
            } else {
                root.lockError = result === PamResult.MaxTries ? "Too many attempts, try again later" : "Incorrect password";
                root.lockFailed();
            }
        }
        onError: {
            root.authenticating = false;
            root.lockPassword = "";
            root.lockError = "Authentication error";
            root.lockFailed();
        }
    }

    WlSessionLock {
        locked: root.locked

        WlSessionLockSurface {
            id: lockSurface
            color: "black"

            Item {
                id: lockContent
                anchors.fill: parent
                opacity: 0
                Component.onCompleted: opacity = 1
                Behavior on opacity { NumberAnimation { duration: 300 } }

                Image {
                    anchors.fill: parent
                    source: root.wallpaper ? `file://${root.wallpaper}` : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }

                // Date and time, just above centre
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.verticalCenter
                    anchors.bottomMargin: 60
                    spacing: -6
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: "#60000000"
                        shadowBlur: 0.6
                        shadowVerticalOffset: 2
                    }

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDateTime(clock.date, "dddd, d MMMM")
                        color: "#d9ffffff"
                        font { pixelSize: 26; weight: Font.Medium }
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDateTime(clock.date, "h:mm AP").replace(/\s*[AP]M$/i, "") // 12-hour like the bar, without AM/PM
                        font { pixelSize: 150; weight: Font.Medium }
                    }
                }

                // Error above the password pill
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: passwordPill.top
                    anchors.bottomMargin: 14
                    text: root.lockError
                    visible: text !== ""
                    layer.enabled: true
                    layer.effect: Shadow {}
                }

                // Password, near the bottom centre, styled like the bar's pills
                Rectangle {
                    id: passwordPill
                    property real shake: 0
                    x: (parent.width - width) / 2 + shake
                    y: parent.height - height - 140
                    width: 300
                    height: 46
                    radius: 23
                    color: "#d9000000"
                    opacity: root.authenticating ? 0.6 : 1
                    layer.enabled: true
                    layer.effect: Shadow {}

                    TextInput {
                        id: lockInput
                        anchors { fill: parent; leftMargin: 20; rightMargin: 20 }
                        verticalAlignment: TextInput.AlignVCenter
                        horizontalAlignment: TextInput.AlignHCenter
                        color: "white"
                        font { family: "Rubik"; pixelSize: 15; letterSpacing: 2 }
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        enabled: !root.authenticating
                        clip: true
                        focus: true
                        // Hide the caret while empty so it doesn't sit on the placeholder
                        cursorDelegate: Rectangle { width: 2; color: "white"; visible: lockInput.text !== "" && lockInput.cursorVisible }
                        text: root.lockPassword
                        onTextChanged: root.lockPassword = text
                        Component.onCompleted: forceActiveFocus()

                        Label {
                            anchors.centerIn: parent
                            visible: lockInput.text === ""
                            text: root.authenticating ? "Checking…" : "Password"
                            color: "#80ffffff"
                            font.pixelSize: 15
                        }

                        Keys.onReturnPressed: root.tryUnlock()
                        Keys.onEnterPressed: root.tryUnlock()
                        Keys.onEscapePressed: root.lockPassword = ""
                    }

                    SequentialAnimation {
                        id: lockShake
                        NumberAnimation { target: passwordPill; property: "shake"; to: -16; duration: 50 }
                        NumberAnimation { target: passwordPill; property: "shake"; to: 14; duration: 70 }
                        NumberAnimation { target: passwordPill; property: "shake"; to: -9; duration: 70 }
                        NumberAnimation { target: passwordPill; property: "shake"; to: 4; duration: 60 }
                        NumberAnimation { target: passwordPill; property: "shake"; to: 0; duration: 50 }
                    }
                    Connections {
                        target: root
                        function onLockFailed() { lockShake.restart(); lockInput.forceActiveFocus(); }
                    }
                }
            }
        }
    }

    // ---- Password prompts (polkit agent); the title island morphs into the prompt ----

    PolkitAgent {
        id: polkit
        onAuthenticationRequestStarted: { root.panel = ""; root.launcherOpen = false; root.mediaOpen = false; root.overviewOpen = false; }
    }

    function formatTime(seconds) {
        const s = Math.max(0, Math.floor(seconds));
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    // ---- Notifications ----

    property var toasts: [] // notifications currently shown as popups

    // Open dropdown and the bar it belongs to
    property string panel: "" // "apps", "airdrop", "audio", "network", "notifications", "power", "calendar" or ""
    property var panelBar: null

    // AirDrop via omdrop; the logic lives in AirDrop.qml, the icon and dropdown are in the tray pill
    AirDrop {
        id: airdrop
        panelOpen: root.panel === "airdrop"
        // Steps aside for the file chooser and comes back on the same bar
        onPanelWanted: open => root.panel = open ? "airdrop" : ""
    }
    // App tray menu shown inside the "apps" dropdown: [app menu, submenu, ...]; empty shows the app list
    property var trayMenus: []
    onPanelChanged: trayMenus = []

    NotificationServer {
        id: notifications
        keepOnReload: true
        actionsSupported: true
        bodySupported: true
        bodyMarkupSupported: false
        imageSupported: false

        onNotification: n => {
            n.tracked = true;
            root.toasts = [...root.toasts, n];
            n.closed.connect(() => root.toasts = root.toasts.filter(t => t !== n));
        }
    }

    // Toasts appear under the tray on the focused monitor
    PanelWindow {
        screen: Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor) ?? Quickshell.screens[0]
        visible: root.toasts.length > 0 && root.panel === "" // they'd cover the dropdown
        anchors { top: true; right: true }
        margins { top: 40; right: 0 }
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-toasts"
        implicitWidth: 400
        implicitHeight: toastColumn.implicitHeight + 30
        color: "transparent"
        mask: Region { item: toastColumn }

        Column {
            id: toastColumn
            x: 10
            y: 14 // 10px below the pills (window starts at 40)
            width: 380
            spacing: 8

            Repeater {
                model: root.toasts

                Rectangle {
                    id: toast
                    required property var modelData
                    width: toastColumn.width
                    height: toastBody.implicitHeight + 24
                    radius: 18
                    color: "black"
                    layer.enabled: true
                    layer.effect: Shadow {}

                    // Critical notifications stay until clicked
                    Timer {
                        running: toast.modelData.urgency !== NotificationUrgency.Critical
                        interval: toast.modelData.expireTimeout > 0 ? toast.modelData.expireTimeout : 5000
                        onTriggered: root.toasts = root.toasts.filter(t => t !== toast.modelData)
                    }

                    ColumnLayout {
                        id: toastBody
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 16 }
                        spacing: 2
                        Label { text: toast.modelData.appName; color: "#99ffffff"; font.pixelSize: 11 }
                        Label { text: toast.modelData.summary; font.weight: Font.Medium; elide: Text.ElideRight; Layout.fillWidth: true }
                        Label {
                            text: toast.modelData.body
                            visible: text !== ""
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            color: "#ccffffff"
                        }
                    }

                    // Click: run the default action if there is one, then hide the popup (it stays in the list)
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            toast.modelData.actions.find(a => a.identifier === "default")?.invoke();
                            root.toasts = root.toasts.filter(t => t !== toast.modelData);
                        }
                    }
                }
            }
        }
    }

    // ---- Overview (SUPER+Tab, 4-finger swipe up/down): every workspace with live window previews ----
    // Click a window to focus it or a workspace to switch to it; arrows + Enter pick a workspace; Esc closes

    property bool overviewOpen: false
    onOverviewOpenChanged: if (overviewOpen) { panel = ""; launcherOpen = false; mediaOpen = false; Hyprland.refreshToplevels(); }

    GlobalShortcut {
        name: "overview" // bound in hyprland.lua as hl.dsp.global("quickshell:overview")
        onPressed: root.overviewOpen = !root.overviewOpen
    }

    PanelWindow {
        id: overview
        readonly property var monitor: Hyprland.focusedMonitor
        // 0..1 while opening/closing
        property real shown: root.overviewOpen ? 1 : 0
        Behavior on shown { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        screen: Quickshell.screens.find(s => s.name === monitor?.name) ?? null
        visible: shown > 0
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:overview"
        WlrLayershell.keyboardFocus: root.overviewOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Workspaces 1..highest on this monitor, like the bar's dots
        readonly property int count: Math.max(monitor?.activeWorkspace?.id ?? 1, ...Hyprland.workspaces.values.filter(w => w.id > 0 && w.monitor === monitor).map(w => w.id))
        readonly property int columns: Math.min(count, 4)
        readonly property real tileW: Math.min(width * 0.22, (width - 120 - (columns - 1) * 24) / columns)
        readonly property real tileScale: tileW / Math.max(monitor?.width ?? 1, 1)
        readonly property real tileH: (monitor?.height ?? 0) * tileScale
        property int selected: 0 // keyboard selection, a workspace index

        // Closing hands keyboard focus back to the previous window, which pulls Hyprland back to its workspace,
        // so the switch is sent just after closing
        property string pending: ""
        function run(dispatch) {
            pending = dispatch;
            root.overviewOpen = false;
            pendingTimer.restart();
        }
        function go(id) { run(`hl.dsp.focus({ workspace = ${id} })`); }
        Timer {
            id: pendingTimer
            interval: 60
            onTriggered: Hyprland.dispatch(overview.pending)
        }

        Connections {
            target: root
            function onOverviewOpenChanged() {
                if (!root.overviewOpen) return;
                overview.selected = (overview.monitor?.activeWorkspace?.id ?? 1) - 1;
                keys.forceActiveFocus();
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "black"
            opacity: 0.45 * overview.shown
        }

        Item {
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                const n = overview.count, c = overview.columns;
                if (event.key === Qt.Key_Escape) root.overviewOpen = false;
                else if (event.key === Qt.Key_Right) overview.selected = Math.min(n - 1, overview.selected + 1);
                else if (event.key === Qt.Key_Left) overview.selected = Math.max(0, overview.selected - 1);
                else if (event.key === Qt.Key_Down) overview.selected = Math.min(n - 1, overview.selected + c);
                else if (event.key === Qt.Key_Up) overview.selected = Math.max(0, overview.selected - c);
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) overview.go(overview.selected + 1);
                else return;
                event.accepted = true;
            }

            // Clicking the empty background closes
            MouseArea {
                anchors.fill: parent
                onClicked: root.overviewOpen = false
            }

            Grid {
                anchors.centerIn: parent
                columns: overview.columns
                spacing: 24
                opacity: overview.shown
                scale: 0.94 + 0.06 * overview.shown

                Repeater {
                    model: overview.count

                    Item {
                        id: tile
                        required property int index
                        readonly property int wsId: index + 1
                        readonly property var workspace: Hyprland.workspaces.values.find(w => w.id === wsId) ?? null
                        readonly property bool current: overview.monitor?.activeWorkspace?.id === wsId
                        width: overview.tileW
                        height: overview.tileH + 28

                        // The workspace in miniature: wallpaper, then each window's live preview where it sits
                        ClippingRectangle {
                            id: screenTile
                            width: overview.tileW
                            height: overview.tileH
                            radius: 12
                            color: "black"

                            Image {
                                anchors.fill: parent
                                source: root.wallpaper !== "" ? `file://${root.wallpaper}` : ""
                                fillMode: Image.PreserveAspectCrop
                                sourceSize.width: overview.tileW * 2
                                asynchronous: true
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: overview.go(tile.wsId)
                            }

                            Repeater {
                                // Tiled first, so floating windows draw on top
                                model: (tile.workspace?.toplevels.values ?? []).slice().sort((a, b) => (a.lastIpcObject?.floating ?? false) - (b.lastIpcObject?.floating ?? false))

                                Item {
                                    id: win
                                    required property var modelData
                                    readonly property var ipc: modelData.lastIpcObject
                                    visible: ipc?.at !== undefined
                                    x: ((ipc?.at?.[0] ?? 0) - (overview.monitor?.x ?? 0)) * overview.tileScale
                                    y: ((ipc?.at?.[1] ?? 0) - (overview.monitor?.y ?? 0)) * overview.tileScale
                                    width: (ipc?.size?.[0] ?? 0) * overview.tileScale
                                    height: (ipc?.size?.[1] ?? 0) * overview.tileScale

                                    ClippingRectangle {
                                        anchors.fill: parent
                                        radius: 5
                                        color: "#1c1c1e"
                                        ScreencopyView {
                                            anchors.fill: parent
                                            captureSource: root.overviewOpen ? win.modelData.wayland : null
                                            live: true
                                        }
                                    }
                                    // App icon, so small previews stay recognisable
                                    IconImage {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 6
                                        implicitSize: Math.min(28, parent.height / 3)
                                        source: {
                                            const f = root.iconFile(win.modelData.wayland?.appId ?? "");
                                            return f !== "" ? `file://${f}` : "";
                                        }
                                    }
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 5
                                        color: "transparent"
                                        border.width: winArea.containsMouse ? 2 : 0
                                        border.color: "white"
                                    }
                                    MouseArea {
                                        id: winArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: overview.run(`hl.dsp.focus({ window = "address:0x${win.modelData.address}" })`)
                                    }
                                }
                            }
                        }
                        // Outline: white for the keyboard selection, grey for the current workspace
                        Rectangle {
                            anchors.fill: screenTile
                            radius: 12
                            color: "transparent"
                            border.width: overview.selected === tile.index ? 2 : tile.current ? 1 : 0
                            border.color: overview.selected === tile.index ? "white" : "#80ffffff"
                        }
                        Label {
                            anchors.top: screenTile.bottom
                            anchors.topMargin: 8
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: tile.wsId
                            color: tile.current ? "white" : "#99ffffff"
                            font.weight: tile.current ? Font.DemiBold : Font.Normal
                        }
                    }
                }
            }
        }
    }

    // ---- Launcher (SUPER+Space; the title pill morphs into a search bar) ----

    property bool launcherOpen: false
    onLauncherOpenChanged: {
        if (!launcherOpen) return;
        panel = "";
        mediaOpen = false;
        if (launcherMode === "clipboard") clipList.running = true; // refresh history
    }

    property string launcherMode: "apps" // or "clipboard"

    function toggleLauncher(mode) {
        if (launcherOpen && launcherMode === mode) {
            launcherOpen = false;
        } else {
            launcherMode = mode;
            launcherOpen = true;
        }
    }

    GlobalShortcut {
        name: "launcher" // bound in hyprland.lua as hl.dsp.global("quickshell:launcher")
        onPressed: root.toggleLauncher("apps")
    }

    // ---- Clipboard history (cliphist, fed by wl-paste --watch in hyprland.lua) ----

    GlobalShortcut {
        name: "clipboard" // bound in hyprland.lua as hl.dsp.global("quickshell:clipboard")
        onPressed: root.toggleLauncher("clipboard")
    }

    // Newest first: { line, id, text, image } where line is cliphist's raw "id<TAB>preview"
    property var clipEntries: []

    Process {
        id: clipList
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: root.clipEntries = text.split("\n").filter(l => l.includes("\t")).map(line => {
                const tab = line.indexOf("\t");
                const preview = line.slice(tab + 1);
                return { line, id: line.slice(0, tab), text: preview, image: preview.startsWith("[[ binary data") };
            })
        }
    }
    onLauncherModeChanged: if (launcherMode === "clipboard") clipList.running = true

    function copyClip(entry) {
        Quickshell.execDetached(["sh", "-c", 'cliphist decode "$1" | wl-copy', "sh", entry.id]);
    }

    function deleteClip(entry) {
        Quickshell.execDetached(["sh", "-c", 'printf "%s\\n" "$1" | cliphist delete', "sh", entry.line]);
        clipEntries = clipEntries.filter(e => e !== entry);
    }

    // Apps matching the query, best first: name prefix, word prefix, name contains, then other fields
    function searchApps(query) {
        const q = query.trim().toLowerCase();
        if (q === "") return [];
        const found = [];
        for (const e of DesktopEntries.applications.values) {
            if (e.noDisplay) continue;
            const name = e.name.toLowerCase();
            const score = name.startsWith(q) ? 0
                : name.split(/\s+/).some(w => w.startsWith(q)) ? 1
                : name.includes(q) ? 2
                : [e.genericName, e.id, ...e.keywords].some(f => f && f.toLowerCase().includes(q)) ? 3
                : -1;
            if (score >= 0) found.push({ e, score });
        }
        found.sort((a, b) => a.score - b.score || a.e.name.localeCompare(b.e.name));
        return found.slice(0, 7).map(f => f.e);
    }

    // ---- Bar ----

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            anchors { top: true; left: true; right: true }
            // Fixed height with room for the open launcher and shadows; resizing the surface makes everything flicker.
            // The mask keeps the empty part click-through.
            implicitHeight: 640
            exclusiveZone: 44 // pill bottom (10 + 34); Hyprland gaps_out adds the 10px gap below
            color: "transparent"
            // OnDemand rather than Exclusive: an exclusive layer stops the focus grab seeing clicks outside
            // Password prompts take the keyboard exclusively so the password can't land in another window
            WlrLayershell.keyboardFocus: auth ? WlrKeyboardFocus.Exclusive : launcher ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
            // Only interactive pills take clicks; the rest of the strip passes through.
            mask: Region {
                item: workspacesPill
                Region { item: closeArea }
                Region { item: titlePill }
                Region { item: musicDot }
                Region { item: trayPill }
                Region { item: clockPill }
            }

            readonly property var monitor: Hyprland.monitorFor(modelData)

            // hypridle honours idle inhibitors, so this stops the idle lock and screen-off
            IdleInhibitor {
                window: bar
                enabled: root.keepAwake
            }
            readonly property string panel: root.panelBar === bar ? root.panel : ""
            // The launcher opens on the focused monitor
            readonly property bool launcher: root.launcherOpen && monitor?.name === Hyprland.focusedMonitor?.name
            readonly property bool media: root.mediaOpen && monitor?.name === Hyprland.focusedMonitor?.name
            readonly property bool auth: polkit.isActive && monitor?.name === Hyprland.focusedMonitor?.name

            function toggle(name) {
                root.panel = panel === name ? "" : name;
                root.panelBar = bar;
                root.launcherOpen = false;
                root.mediaOpen = false;
            }

            // While a dropdown or the launcher is open, clicking empty bar space closes it (the focus grab doesn't see clicks on the bar)
            MouseArea {
                id: closeArea
                width: parent.width
                height: bar.panel !== "" || bar.launcher || bar.media ? parent.height : 0
                onClicked: { root.panel = ""; root.launcherOpen = false; root.mediaOpen = false; }
            }

            // Top left: workspaces on this monitor
            Pill {
                id: workspacesPill
                x: 10
                spacing: 6

                Repeater {
                    // Dots 1..highest workspace on this monitor, so gaps show as empty dots and position = number.
                    // A count (not the workspace list) keeps existing dots alive when workspaces come and go.
                    model: Math.max(0, ...Hyprland.workspaces.values.filter(w => w.id > 0 && w.monitor === bar.monitor).map(w => w.id))

                    // A dot per workspace number, wide when active. With windows, it's filled with the main colour of
                    // the first window's app icon; empty workspaces stay grey
                    Rectangle {
                        id: ws
                        required property int index
                        readonly property int wsId: index + 1
                        readonly property var workspace: Hyprland.workspaces.values.find(w => w.id === wsId) ?? null
                        readonly property bool active: bar.monitor?.activeWorkspace?.id === wsId
                        readonly property string app: (workspace?.toplevels.values ?? []).map(t => t.wayland?.appId ?? "").find(a => a !== "") ?? ""
                        // From the shared cache, so dots the Repeater rebuilds get their colour straight away
                        readonly property var appColor: root.appColors[app]
                        implicitHeight: 8
                        implicitWidth: active ? 22 : 8
                        radius: 4
                        // Grey (not white) while an app's colour is first computed. No colour animation: it showed
                        // as a white flash whenever the dots were rebuilt
                        color: app === "" ? (active ? "white" : "#66ffffff") : appColor === undefined ? "#66ffffff" : active ? appColor : Qt.alpha(appColor, 0.6)

                        Behavior on implicitWidth { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.25 } }

                        // Computes an app's colour once, then the cache takes over
                        ColorQuantizer {
                            source: ws.app !== "" && ws.appColor === undefined && root.iconFile(ws.app) !== "" ? `file://${root.iconFile(ws.app)}` : ""
                            depth: 3 // up to 8 colours
                            rescaleSize: 32
                            onColorsChanged: if (colors.length > 0 && ws.app !== "") root.appColors = Object.assign({}, root.appColors, { [ws.app]: root.vividColor(colors) })
                        }

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            // workspace.activate() sends legacy dispatch syntax, which the Lua config rejects
                            onClicked: {
                                root.panel = "";
                                Hyprland.dispatch(`hl.dsp.focus({ workspace = ${parent.wsId} })`);
                            }
                        }
                    }
                }
            }

            // Top middle: a music circle (while something plays) and the window title, centred together.
            // The title island morphs into the launcher or, from the circle, the media player.
            readonly property bool showDot: (root.player?.isPlaying ?? false) && !titlePill.morphed
            // 0..1 while the circle slides in or out
            property real dotAmount: showDot ? 1 : 0
            Behavior on dotAmount { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.01 } }
            readonly property real dotSlot: dotAmount * (34 + (titlePill.visible ? 6 : 0))
            readonly property real groupLeft: (width - dotSlot - (titlePill.visible ? titlePill.width : 0)) / 2

            Rectangle {
                id: musicDot
                x: bar.groupLeft
                y: 10
                width: 34
                height: 34
                radius: 17
                color: "black"
                opacity: Math.min(1, Math.max(0, bar.dotAmount))
                scale: 0.6 + 0.4 * opacity
                visible: opacity > 0.01
                layer.enabled: true
                layer.effect: Shadow {}

                Icon { anchors.centerIn: parent; text: "music_note" }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.mediaOpen = true
                }
            }

            Rectangle {
                id: titlePill
                readonly property string title: ToplevelManager.activeToplevel?.title ?? ""
                readonly property bool open: bar.launcher
                readonly property bool media: bar.media
                readonly property bool auth: bar.auth
                // Volume/brightness popup, only while nothing else has the island
                // (not for volume while the audio panel shows the slider)
                readonly property bool osd: root.osdKind !== "" && !open && !media && !auth && !(root.osdKind === "volume" && bar.panel === "audio") && bar.monitor?.name === Hyprland.focusedMonitor?.name
                readonly property bool morphed: open || media || auth || osd
                property real shake: 0 // sideways offset for the wrong-password shake
                readonly property bool clipMode: root.launcherMode === "clipboard"
                readonly property var apps: open && !clipMode ? root.searchApps(search.text) : []
                // Clipboard mode: history entries containing the query, newest first
                readonly property var clips: open && clipMode
                    ? root.clipEntries.filter(e => e.text.toLowerCase().includes(search.text.trim().toLowerCase())).slice(0, 8)
                    : []
                // Results: matching apps, then "run as command" whenever something is typed; or clipboard entries
                readonly property int resultCount: clipMode ? clips.length : apps.length + (search.text.trim() !== "" ? 1 : 0)
                property int selected: 0

                x: bar.groupLeft + bar.dotSlot + shake
                y: 10
                visible: morphed || title !== "" || height > 36
                width: auth ? 460 : open ? 640 : media ? 520 : osd ? 320 : Math.min(titleLabel.implicitWidth, 600) + 28
                height: auth ? authBody.implicitHeight + 36 : open ? 46 + (resultCount > 0 ? resultCount * 40 + 8 : 0) : media ? 132 : osd ? 40 : 34
                radius: auth ? 30 : open ? 23 : media ? 30 : osd ? 20 : 17
                color: "black"
                clip: true

                // Springy resize for the morph
                Behavior on width { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.5 } }
                Behavior on height { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.5 } }
                Behavior on radius { NumberAnimation { duration: 200 } }

                layer.enabled: true
                layer.effect: Shadow {}

                onOpenChanged: {
                    search.text = "";
                    selected = 0;
                    if (open) search.forceActiveFocus();
                }
                onResultCountChanged: selected = 0
                onClipModeChanged: { search.text = ""; selected = 0; }

                function launch(index, inTerminal) {
                    if (clipMode) {
                        if (index >= clips.length) return;
                        root.copyClip(clips[index]);
                        root.launcherOpen = false;
                        return;
                    }
                    const cmd = search.text.trim();
                    if (index < apps.length) apps[index].execute();
                    else if (cmd !== "") Quickshell.execDetached(inTerminal ? ["kitty", "--hold", "sh", "-c", cmd] : ["sh", "-c", cmd]);
                    else return;
                    root.launcherOpen = false;
                }

                // Clip here, not on the island: its shadow layer pads the area and would show content outside it mid-morph
                Item {
                    anchors.fill: parent
                    clip: true

                // Swallow clicks on empty launcher space so they don't reach the close area underneath
                MouseArea { anchors.fill: parent; enabled: titlePill.morphed }

                Label {
                    id: titleLabel
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, 600)
                    text: titlePill.title
                    elide: Text.ElideRight
                    // Also waits for the volume/brightness popup to fade out
                    opacity: titlePill.morphed || osdBody.visible ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 90 } }
                }

                // Volume / brightness popup: icon, level bar, percentage
                RowLayout {
                    id: osdBody
                    // The kind being shown; kept while the popup fades out (osdKind is "" by then)
                    property string kind: "volume"
                    Connections {
                        target: root
                        function onOsdKindChanged() { if (root.osdKind !== "") osdBody.kind = root.osdKind; }
                    }
                    readonly property bool isVolume: kind === "volume"
                    readonly property bool muted: isVolume && root.muted
                    readonly property real level: Math.min(1, isVolume ? root.volume : root.brightness / 100)
                    // Animated level for the fill, so its width never animates against the pill's own resize
                    property real shownLevel: level
                    Behavior on shownLevel { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    // Laid out at the popup's final size and centred, so the morph from a wide title doesn't stretch it
                    anchors.centerIn: parent
                    width: 320 - 32
                    height: 40
                    spacing: 12
                    // Fades in once the title has faded out, and out before the title returns, so they never overlap.
                    // Explicit animations: a SequentialAnimation inside a Behavior didn't run on close
                    opacity: 0
                    visible: opacity > 0
                    Connections {
                        target: titlePill
                        function onOsdChanged() {
                            osdFadeIn.stop();
                            osdFadeOut.stop();
                            (titlePill.osd ? osdFadeIn : osdFadeOut).start();
                        }
                    }
                    SequentialAnimation {
                        id: osdFadeIn
                        PauseAnimation { duration: 90 }
                        NumberAnimation { target: osdBody; property: "opacity"; to: 1; duration: 150 }
                    }
                    NumberAnimation { id: osdFadeOut; target: osdBody; property: "opacity"; to: 0; duration: 90 }

                    Icon {
                        Layout.preferredWidth: 22
                        horizontalAlignment: Text.AlignHCenter
                        text: !osdBody.isVolume ? (osdBody.level < 0.5 ? "sun_min_fill" : "sun_max_fill")
                            : root.volumeIcon
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 6
                        radius: 3
                        color: "#33ffffff"
                        Rectangle {
                            width: parent.width * osdBody.shownLevel
                            height: parent.height
                            radius: 3
                            color: osdBody.muted ? "#66ffffff" : "white"
                        }
                    }
                    Label {
                        Layout.preferredWidth: 34
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(osdBody.level * 100)
                        color: osdBody.muted ? "#99ffffff" : "white"
                    }
                }

                // Password prompt
                Item {
                    id: authPrompt
                    anchors.fill: parent
                    opacity: titlePill.auth ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    readonly property var flow: polkit.flow

                    function submit() {
                        if (!flow || !flow.isResponseRequired) return;
                        flow.submit(password.text);
                        password.text = "";
                    }

                    // Focus the field whenever polkit asks for input (again, after a wrong password)
                    Connections {
                        target: polkit.flow
                        function onIsResponseRequiredChanged() { if (polkit.flow.isResponseRequired) password.forceActiveFocus(); }
                        function onAuthenticationFailed() { shakeAnim.restart(); }
                    }
                    Connections {
                        target: titlePill
                        function onAuthChanged() { password.text = ""; if (titlePill.auth) password.forceActiveFocus(); }
                    }

                    SequentialAnimation {
                        id: shakeAnim
                        NumberAnimation { target: titlePill; property: "shake"; to: -14; duration: 50 }
                        NumberAnimation { target: titlePill; property: "shake"; to: 12; duration: 70 }
                        NumberAnimation { target: titlePill; property: "shake"; to: -8; duration: 70 }
                        NumberAnimation { target: titlePill; property: "shake"; to: 4; duration: 60 }
                        NumberAnimation { target: titlePill; property: "shake"; to: 0; duration: 50 }
                    }

                    ColumnLayout {
                        id: authBody
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
                        spacing: 12

                        RowLayout {
                            spacing: 12
                            Icon { text: "lock_fill"; font.pixelSize: 22; Layout.alignment: Qt.AlignTop }
                            ColumnLayout {
                                spacing: 2
                                Label { text: "Authentication required"; font { pixelSize: 15; weight: Font.Medium } }
                                Label {
                                    Layout.fillWidth: true
                                    text: authPrompt.flow?.message ?? ""
                                    color: "#99ffffff"
                                    wrapMode: Text.Wrap
                                }
                            }
                        }

                        // Password field
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 40
                            radius: 14
                            color: "#1affffff"
                            border.width: 1
                            border.color: password.activeFocus ? "#40ffffff" : "transparent"

                            TextInput {
                                id: password
                                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                                verticalAlignment: TextInput.AlignVCenter
                                color: "white"
                                font { family: "Rubik"; pixelSize: 15 }
                                echoMode: polkit.flow?.responseVisible ? TextInput.Normal : TextInput.Password
                                passwordCharacter: "•"
                                enabled: polkit.flow?.isResponseRequired ?? false
                                clip: true

                                Label {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: password.text === ""
                                    // polkit's prompt is usually "Password: "
                                    text: (polkit.flow?.inputPrompt || "Password").replace(/:\s*$/, "")
                                    color: "#66ffffff"
                                    font.pixelSize: 15
                                }

                                Keys.onReturnPressed: authPrompt.submit()
                                Keys.onEnterPressed: authPrompt.submit()
                                Keys.onEscapePressed: polkit.flow?.cancelAuthenticationRequest()
                            }
                        }

                        // Error or info from polkit, e.g. a wrong password
                        Label {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: polkit.flow?.supplementaryMessage ?? ""
                            color: polkit.flow?.supplementaryIsError ? "#ff6961" : "#99ffffff"
                            wrapMode: Text.Wrap
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Item { Layout.fillWidth: true }
                            Rectangle {
                                implicitWidth: 96
                                implicitHeight: 34
                                radius: 17
                                color: cancelArea.containsMouse ? "#33ffffff" : "#1affffff"
                                Label { anchors.centerIn: parent; text: "Cancel" }
                                MouseArea {
                                    id: cancelArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: polkit.flow?.cancelAuthenticationRequest()
                                }
                            }
                            Rectangle {
                                implicitWidth: 120
                                implicitHeight: 34
                                radius: 17
                                color: "white"
                                opacity: authArea.containsMouse ? 0.85 : 1
                                Label { anchors.centerIn: parent; text: "Authenticate"; color: "black"; font.weight: Font.Medium }
                                MouseArea {
                                    id: authArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: authPrompt.submit()
                                }
                            }
                        }
                    }
                }

                // Media player
                Item {
                    anchors.fill: parent
                    opacity: titlePill.media ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    // MPRIS doesn't push position updates, so ask for them while playing
                    Timer {
                        running: titlePill.media && (root.player?.isPlaying ?? false)
                        interval: 1000
                        repeat: true
                        triggeredOnStart: true
                        onTriggered: root.player.positionChanged()
                    }

                    RowLayout {
                        anchors { fill: parent; margins: 14 }
                        spacing: 16

                        ClippingRectangle {
                            implicitWidth: 104
                            implicitHeight: 104
                            radius: 18
                            color: "#1affffff"

                            Image {
                                id: art
                                anchors.fill: parent
                                source: root.player?.trackArtUrl ?? ""
                                fillMode: Image.PreserveAspectCrop
                                sourceSize: Qt.size(208, 208)
                                asynchronous: true
                            }
                            Icon {
                                anchors.centerIn: parent
                                visible: art.status !== Image.Ready
                                text: "music_note"
                                color: "#66ffffff"
                                font.pixelSize: 40
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 2

                            Label {
                                Layout.fillWidth: true
                                text: root.player?.trackTitle || root.player?.identity || ""
                                font { pixelSize: 15; weight: Font.Medium }
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.fillWidth: true
                                text: root.player?.trackArtist ?? ""
                                color: "#99ffffff"
                                elide: Text.ElideRight
                            }
                            Item { Layout.fillHeight: true }

                            // Progress (click to seek)
                            Item {
                                id: progress
                                readonly property real length: root.player?.length ?? 0
                                Layout.fillWidth: true
                                implicitHeight: 12
                                visible: (root.player?.lengthSupported ?? false) && length > 0

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    height: 4
                                    radius: 2
                                    color: "#33ffffff"
                                    Rectangle {
                                        width: parent.width * Math.min(1, (root.player?.position ?? 0) / Math.max(progress.length, 1))
                                        height: parent.height
                                        radius: 2
                                        color: "white"
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: root.player?.canSeek ?? false
                                    onClicked: mouse => root.player.position = mouse.x / width * progress.length
                                }
                            }
                            RowLayout {
                                visible: progress.visible
                                Layout.fillWidth: true
                                Label { text: root.formatTime(root.player?.position ?? 0); color: "#99ffffff"; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                Label { text: root.formatTime(progress.length); color: "#99ffffff"; font.pixelSize: 11 }
                            }

                            RowLayout {
                                Layout.alignment: Qt.AlignHCenter
                                spacing: 22
                                IconButton {
                                    text: "backward_end_fill"
                                    font.pixelSize: 24
                                    enabled: root.player?.canGoPrevious ?? false
                                    opacity: enabled ? 1 : 0.4
                                    onClicked: root.player.previous()
                                }
                                IconButton {
                                    text: root.player?.isPlaying ? "pause_fill" : "play_fill"
                                    font.pixelSize: 30
                                    enabled: root.player?.canTogglePlaying ?? false
                                    onClicked: root.player.togglePlaying()
                                }
                                IconButton {
                                    text: "forward_end_fill"
                                    font.pixelSize: 24
                                    enabled: root.player?.canGoNext ?? false
                                    opacity: enabled ? 1 : 0.4
                                    onClicked: root.player.next()
                                }
                            }
                        }
                    }
                }

                Item {
                    anchors.fill: parent
                    opacity: titlePill.open ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    RowLayout {
                        id: searchRow
                        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 18; rightMargin: 18 }
                        height: 46
                        spacing: 10
                        Icon { text: titlePill.clipMode ? "doc_on_clipboard" : "search"; color: "#99ffffff" }
                        TextInput {
                            id: search
                            Layout.fillWidth: true
                            color: "white"
                            selectionColor: "#55ffffff"
                            font { family: "Rubik"; pixelSize: 15 }
                            clip: true

                            Label {
                                visible: search.text === ""
                                text: titlePill.clipMode ? "Search clipboard history" : "Search apps or run a command"
                                color: "#66ffffff"
                                font.pixelSize: 15
                            }

                            Keys.onPressed: event => {
                                const n = titlePill.resultCount;
                                if (event.key === Qt.Key_Escape) {
                                    root.launcherOpen = false;
                                } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && n > 0)) {
                                    titlePill.selected = (titlePill.selected + 1) % Math.max(n, 1);
                                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) {
                                    titlePill.selected = (titlePill.selected - 1 + Math.max(n, 1)) % Math.max(n, 1);
                                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    titlePill.launch(titlePill.selected, event.modifiers & Qt.ShiftModifier);
                                } else if (event.key === Qt.Key_Delete && (event.modifiers & Qt.ShiftModifier) && titlePill.clipMode && n > 0) {
                                    root.deleteClip(titlePill.clips[titlePill.selected]);
                                } else {
                                    return;
                                }
                                event.accepted = true;
                            }
                        }
                    }

                    Column {
                        anchors { left: parent.left; right: parent.right; top: searchRow.bottom; margins: 6; topMargin: 0 }

                        Repeater {
                            model: titlePill.resultCount

                            Rectangle {
                                id: result
                                required property int index
                                readonly property var app: titlePill.apps[index] ?? null
                                readonly property var clipEntry: titlePill.clips[index] ?? null
                                width: parent.width
                                height: 40
                                radius: 14
                                color: titlePill.selected === index ? "#26ffffff" : "transparent"

                                RowLayout {
                                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                    spacing: 12
                                    IconImage {
                                        visible: result.app !== null
                                        source: result.app ? Quickshell.iconPath(result.app.icon, "application-x-executable") : ""
                                        implicitSize: 22
                                    }
                                    Icon {
                                        visible: result.app === null
                                        text: result.clipEntry ? (result.clipEntry.image ? "photo" : "doc_text") : "greaterthan_square"
                                        Layout.preferredWidth: 22
                                    }
                                    Label {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        textFormat: Text.StyledText
                                        text: result.clipEntry
                                            ? result.clipEntry.text.replace(/&/g, "&amp;").replace(/</g, "&lt;")
                                            : result.app
                                            ? `${result.app.name}${result.app.genericName ? `  <font color="#66ffffff">${result.app.genericName}</font>` : ""}`
                                            : `Run <font color="#99ffffff">${search.text.trim().replace(/&/g, "&amp;").replace(/</g, "&lt;")}</font>`
                                    }
                                    Label {
                                        visible: result.app === null && titlePill.selected === result.index
                                        text: result.clipEntry ? "Shift+Del: remove" : "Shift+Enter: in terminal"
                                        color: "#66ffffff"
                                        font.pixelSize: 11
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onEntered: titlePill.selected = result.index
                                    onClicked: mouse => titlePill.launch(result.index, mouse.modifiers & Qt.ShiftModifier)
                                }
                            }
                        }
                    }
                }
                }
            }

            // Top right: time/date, then system tray
            Row {
                id: rightPills
                anchors.right: parent.right
                anchors.rightMargin: 10
                spacing: 10

                // Clock; clicking it morphs the pill into a month calendar below the time
                Rectangle {
                    id: clockPill
                    readonly property bool open: bar.panel === "calendar"
                    property int monthOffset: 0 // months away from the current one
                    readonly property date shown: new Date(clock.date.getFullYear(), clock.date.getMonth() + monthOffset, 1)
                    // First cell: the week day the locale starts weeks on, on or before the 1st
                    readonly property int lead: (shown.getDay() - Qt.locale().firstDayOfWeek % 7 + 7) % 7
                    onOpenChanged: monthOffset = 0

                    y: 10
                    width: open ? 7 * 36 + 24 : clockLabel.implicitWidth + 28
                    height: open ? 34 + calendar.implicitHeight + 10 : 34
                    radius: open ? 22 : 17
                    color: "black"

                    Behavior on width { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.5 } }
                    Behavior on height { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.5 } }
                    Behavior on radius { NumberAnimation { duration: 200 } }

                    layer.enabled: true
                    layer.effect: Shadow {}

                    // Clip here, not on the pill: its shadow layer pads the area and would show content outside it mid-morph
                    Item {
                        anchors.fill: parent
                        clip: true

                        MouseArea {
                            anchors.fill: parent
                            onClicked: if (!clockPill.open) bar.toggle("calendar")
                            onWheel: wheel => { if (clockPill.open) clockPill.monthOffset += wheel.angleDelta.y > 0 ? -1 : 1; }
                        }

                        Label {
                            id: clockLabel
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: 34
                            verticalAlignment: Text.AlignVCenter
                            text: Qt.formatDateTime(clock.date, "ddd d MMM  h:mm AP")
                            font.weight: Font.Medium
                            MouseArea { anchors.fill: parent; onClicked: bar.toggle("calendar") }
                        }

                        ColumnLayout {
                            id: calendar
                            anchors { left: parent.left; right: parent.right; top: clockLabel.bottom; margins: 12; topMargin: 2 }
                            spacing: 4
                            opacity: clockPill.open ? 1 : 0
                            visible: opacity > 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }

                            // Month and year, with previous / next
                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 6
                                    text: Qt.formatDate(clockPill.shown, "MMMM yyyy")
                                    font.weight: Font.DemiBold
                                }
                                IconButton { text: "chevron_left"; font.pixelSize: 13; closesPanel: false; onClicked: clockPill.monthOffset-- }
                                IconButton { text: "chevron_right"; font.pixelSize: 13; closesPanel: false; onClicked: clockPill.monthOffset++ }
                            }

                            Grid {
                                columns: 7
                                // Week day initials
                                Repeater {
                                    model: 7
                                    Label {
                                        required property int index
                                        width: 36
                                        height: 24
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        text: Qt.locale().dayName((Qt.locale().firstDayOfWeek + index) % 7, Locale.NarrowFormat)
                                        color: "#80ffffff"
                                        font.pixelSize: 11
                                    }
                                }
                                // Six weeks; days outside the month are dimmed, today is filled
                                Repeater {
                                    model: 42
                                    Item {
                                        required property int index
                                        readonly property date day: new Date(clockPill.shown.getFullYear(), clockPill.shown.getMonth(), index - clockPill.lead + 1)
                                        readonly property bool inMonth: day.getMonth() === clockPill.shown.getMonth()
                                        readonly property bool today: day.toDateString() === clock.date.toDateString()
                                        width: 36
                                        height: 32
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: 28
                                            height: 28
                                            radius: 14
                                            color: "white"
                                            visible: parent.today
                                        }
                                        Label {
                                            anchors.centerIn: parent
                                            text: parent.day.getDate()
                                            color: parent.today ? "black" : parent.inMonth ? "white" : "#4dffffff"
                                            font.weight: parent.today ? Font.DemiBold : Font.Normal
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // System tray; opening a menu morphs the pill into a panel below its icons
                Rectangle {
                    id: trayPill
                    readonly property bool open: bar.panel !== "" && bar.panel !== "calendar"
                    // The panel whose content is shown; kept while the pill shrinks back so it can fade out
                    property string shownPanel: ""
                    Connections {
                        target: bar
                        function onPanelChanged() { if (trayPill.open) trayPill.shownPanel = bar.panel; }
                    }

                    y: 10
                    width: open ? 340 : trayIcons.implicitWidth + 28
                    height: open ? trayIcons.height + panelBody.implicitHeight + 10 : 34
                    radius: open ? 22 : 17
                    color: "black"
                    clip: true

                    Behavior on width { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.5 } }
                    Behavior on height { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.5 } }
                    Behavior on radius { NumberAnimation { duration: 200 } }

                    layer.enabled: true
                    layer.effect: Shadow {}

                    // Clip here, not on the pill: its shadow layer pads the area and would show content outside the pill mid-morph
                    Item {
                        anchors.fill: parent
                        clip: true

                    // Swallow clicks on empty panel space so they don't reach the close area underneath
                    MouseArea { anchors.fill: parent; enabled: trayPill.open }

                    RowLayout {
                        id: trayIcons
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        height: 34
                        spacing: 12

                        // Tray icons from other apps live in a dropdown rather than on the bar
                        IconButton {
                            id: appsButton
                            visible: SystemTray.items.values.length > 0
                            text: bar.panel === "apps" ? "chevron_up" : "chevron_down"
                            font.pixelSize: 10 // small, like the Material chevron
                            closesPanel: false
                            onClicked: bar.toggle("apps")
                        }

                        // AirDrop: click for the dropdown, right-click to turn it on or off. Dim while off.
                        IconButton {
                            Layout.preferredWidth: 17
                            closesPanel: false
                            onClicked: bar.toggle("airdrop")
                            Image {
                                anchors.centerIn: parent
                                source: "icons/airdrop.svg"
                                sourceSize: Qt.size(17, 17)
                                opacity: !airdrop.usable ? 0.3 : airdrop.receiving || airdrop.busy ? 1 : 0.5
                                Behavior on opacity { NumberAnimation { duration: 200 } }
                                // Breathes while the radio is coming up
                                SequentialAnimation on scale {
                                    running: airdrop.busy || airdrop.settling
                                    loops: Animation.Infinite
                                    onRunningChanged: if (!running) parent.scale = 1
                                    NumberAnimation { to: 0.8; duration: 600; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                onClicked: airdrop.toggle()
                            }
                        }

                        // Volume: click for the audio panel, scroll to change volume
                        IconButton {
                            text: root.volumeIcon
                            // Fixed width: the speaker glyphs widen with the level and would nudge the pill
                            Layout.preferredWidth: 22
                            horizontalAlignment: Text.AlignHCenter
                            closesPanel: false
                            onClicked: bar.toggle("audio")
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.NoButton
                                onWheel: wheel => {
                                    if (!root.sink?.audio) return;
                                    root.sink.audio.volume = Math.max(0, Math.min(1, root.volume + (wheel.angleDelta.y > 0 ? 0.02 : -0.02)));
                                }
                            }
                        }
                        IconButton {
                            text: root.ethernet && root.wifiName === "" ? "arrow_left_right" : root.wifiIcon
                            closesPanel: false
                            onClicked: bar.toggle("network")
                        }
                        IconButton {
                            visible: root.btConnected
                            Layout.preferredWidth: 17
                            closesPanel: false
                            onClicked: bar.toggle("network")
                            Image { anchors.centerIn: parent; source: "icons/bluetooth.svg"; sourceSize: Qt.size(17, 17) }
                        }
                        // Only shown while there are notifications; the list closes once they're all cleared
                        IconButton {
                            text: "bell_fill"
                            visible: notifications.trackedNotifications.values.length > 0
                            onVisibleChanged: if (!visible && bar.panel === "notifications") root.panel = ""
                            closesPanel: false
                            onClicked: bar.toggle("notifications")
                        }
                        IconButton {
                            text: "power"
                            closesPanel: false
                            onClicked: bar.toggle("power")
                        }
                    }

                    ColumnLayout {
                        id: panelBody
                        anchors { left: parent.left; right: parent.right; top: trayIcons.bottom; margins: 8; topMargin: 2 }
                        spacing: 2
                        opacity: trayPill.open ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        // App tray (StatusNotifierItem)
                        Repeater {
                            model: trayPill.shownPanel === "apps" && root.trayMenus.length === 0 ? SystemTray.items.values : []

                            Rectangle {
                                id: trayRow
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 34
                                radius: 10
                                color: trayArea.containsMouse ? "#22ffffff" : "transparent"

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    spacing: 10
                                    IconImage {
                                        // Some apps (LocalSend) give a file path as the icon name, which the icon theme lookup can't find
                                        source: {
                                            const m = trayRow.modelData.icon.match(/^image:\/\/icon\/(\/[^?]*)/);
                                            return m ? `file://${m[1]}` : trayRow.modelData.icon;
                                        }
                                        implicitSize: 18
                                    }
                                    Label {
                                        // Prefer a real app name: some apps set an app ID as the title, others only a status tooltip
                                        text: {
                                            const item = trayRow.modelData;
                                            const key = (item.title || item.id).toLowerCase();
                                            // e.g. title "org.localsend.localsend_app" -> localsend.desktop
                                            const entry = DesktopEntries.heuristicLookup(key)
                                                ?? DesktopEntries.applications.values.find(e => e.id.length >= 4 && key.includes(e.id.toLowerCase().split(".").pop()));
                                            const name = entry?.name || (item.title.includes(".") ? "" : item.title);
                                            return name || item.tooltipTitle.split("\n")[0] || item.id;
                                        }
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }

                                MouseArea {
                                    id: trayArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                    // Left: open the app (or its menu if that's all it has), right: its menu, middle: secondary action.
                                    // Menus show inside this dropdown; a separate popup menu can't open from here.
                                    onClicked: mouse => {
                                        const item = trayRow.modelData;
                                        if (mouse.button !== Qt.MiddleButton && (mouse.button === Qt.RightButton || item.onlyMenu)) {
                                            if (item.hasMenu) root.trayMenus = [item.menu];
                                            return;
                                        }
                                        root.panel = "";
                                        if (mouse.button === Qt.MiddleButton) item.secondaryActivate();
                                        else item.activate();
                                    }
                                    onWheel: wheel => trayRow.modelData.scroll(wheel.angleDelta.y, false)
                                }
                            }
                        }

                        // App tray menu
                        QsMenuOpener {
                            id: trayMenu
                            menu: root.trayMenus[root.trayMenus.length - 1] ?? null
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "apps" && root.trayMenus.length > 0
                            icon: "chevron_left"
                            label: "Back"
                            onClicked: root.trayMenus = root.trayMenus.slice(0, -1)
                        }
                        Repeater {
                            model: trayPill.shownPanel === "apps" && root.trayMenus.length > 0 ? trayMenu.children.values : []

                            Item {
                                id: menuEntry
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: modelData.isSeparator ? 9 : 34

                                Rectangle {
                                    visible: menuEntry.modelData.isSeparator
                                    anchors.centerIn: parent
                                    width: parent.width - 20
                                    height: 1
                                    color: "#33ffffff"
                                }

                                Rectangle {
                                    visible: !menuEntry.modelData.isSeparator
                                    anchors.fill: parent
                                    radius: 10
                                    color: entryArea.containsMouse && menuEntry.modelData.enabled ? "#22ffffff" : "transparent"
                                    opacity: menuEntry.modelData.enabled ? 1 : 0.4

                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                        spacing: 10
                                        Icon {
                                            visible: menuEntry.modelData.buttonType !== QsMenuButtonType.None
                                            text: menuEntry.modelData.buttonType === QsMenuButtonType.RadioButton
                                                ? (menuEntry.modelData.checkState === Qt.Checked ? "largecircle_fill_circle" : "circle")
                                                : (menuEntry.modelData.checkState === Qt.Checked ? "checkmark_square_fill" : "square")
                                        }
                                        Label {
                                            text: menuEntry.modelData.text.replace(/_(?!_)/g, "") // drop mnemonic underscores
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Icon { visible: menuEntry.modelData.hasChildren; text: "chevron_right" }
                                    }

                                    MouseArea {
                                        id: entryArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: menuEntry.modelData.enabled
                                        onClicked: {
                                            const entry = menuEntry.modelData;
                                            if (entry.hasChildren) {
                                                root.trayMenus = [...root.trayMenus, entry];
                                            } else {
                                                entry.triggered();
                                                root.panel = "";
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // AirDrop: on/off, how long to stay visible, who may send, nearby devices to send to, save folder
                        Rectangle {
                            visible: trayPill.shownPanel === "airdrop"
                            Layout.fillWidth: true
                            implicitHeight: 44
                            radius: 10
                            color: airdropArea.containsMouse && airdrop.usable ? "#22ffffff" : "transparent"

                            RowLayout {
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                spacing: 10
                                Image { source: "icons/airdrop.svg"; sourceSize: Qt.size(17, 17); Layout.preferredWidth: 20; fillMode: Image.Pad; opacity: airdrop.receiving ? 1 : 0.6 }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Label { text: "AirDrop"; font.weight: Font.Medium; Layout.fillWidth: true }
                                    Label { text: airdrop.stateText; color: "#99ffffff"; font.pixelSize: 11; Layout.fillWidth: true }
                                }
                                // Switch; shows where it's going while busy
                                Rectangle {
                                    visible: airdrop.usable
                                    readonly property bool on: airdrop.busy ? airdrop.turningOn : airdrop.receiving
                                    implicitWidth: 34
                                    implicitHeight: 20
                                    radius: 10
                                    color: on ? "white" : "#33ffffff"
                                    opacity: airdrop.busy ? 0.6 : 1
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Rectangle {
                                        width: 16
                                        height: 16
                                        radius: 8
                                        y: 2
                                        x: parent.on ? parent.width - width - 2 : 2
                                        color: parent.on ? "black" : "white"
                                        Behavior on x { SpringAnimation { spring: 5; damping: 0.4; epsilon: 0.25 } }
                                    }
                                }
                            }
                            MouseArea {
                                id: airdropArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: airdrop.toggle()
                            }
                        }
                        Label {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.detailText !== ""
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.bottomMargin: 4
                            text: airdrop.detailText
                            color: "#99ffffff"
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                        Rectangle {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.usable
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            implicitHeight: 1
                            color: "#26ffffff"
                        }
                        // Stay visible for: discrete stops; releasing during a window restarts it at the new length
                        RowLayout {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.usable
                            Layout.margins: 6
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            spacing: 10
                            Icon { text: "timer"; Layout.preferredWidth: 22; horizontalAlignment: Text.AlignHCenter }
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 20
                                readonly property int last: airdrop.windowStops.length - 1
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    height: 6
                                    radius: 3
                                    color: "#33ffffff"
                                    Rectangle {
                                        width: 6 + (parent.width - 6) * airdrop.windowIndex / parent.parent.last
                                        height: parent.height
                                        radius: 3
                                        color: "white"
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -10
                                    function set(x) { airdrop.windowIndex = Math.max(0, Math.min(parent.last, Math.round((x - 10) / (width - 20) * parent.last))); }
                                    onPressed: mouse => { airdrop.windowPicking = true; set(mouse.x); }
                                    onPositionChanged: mouse => set(mouse.x)
                                    onReleased: { airdrop.windowPicking = false; airdrop.reschedule(); }
                                    onWheel: wheel => {
                                        airdrop.windowIndex = Math.max(0, Math.min(parent.last, airdrop.windowIndex + (wheel.angleDelta.y > 0 ? 1 : -1)));
                                        airdrop.reschedule();
                                    }
                                }
                            }
                            Label {
                                Layout.preferredWidth: 64
                                horizontalAlignment: Text.AlignRight
                                text: airdrop.windowText
                                color: airdrop.countingDown && airdrop.remaining <= 60 ? "#ff453a" : "white"
                            }
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.usable
                            icon: airdrop.audience === "everyone" ? "checkmark_alt" : ""
                            label: "Everyone"
                            onClicked: airdrop.setAudience("everyone")
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.usable
                            icon: airdrop.audience === "contacts" ? "checkmark_alt" : ""
                            label: `Contacts only  ·  ${airdrop.senders} known ${airdrop.senders === 1 ? "sender" : "senders"}`
                            onClicked: airdrop.setAudience("contacts")
                        }
                        Rectangle {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.usable
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            implicitHeight: 1
                            color: "#26ffffff"
                        }
                        Label {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.usable
                            Layout.margins: 6
                            Layout.leftMargin: 10
                            text: !airdrop.receiving ? "Turn AirDrop on to send to nearby devices"
                                : !airdrop.scanning ? "Waiting for the radio…"
                                : airdrop.peers.length === 0 ? "Looking for nearby devices…" : "Send to"
                            color: "#99ffffff"
                            font.pixelSize: 11
                        }
                        // Click a device to pick files for it; click the device being sent to, to cancel or clear the result
                        Repeater {
                            model: trayPill.shownPanel === "airdrop" && airdrop.usable ? airdrop.peers : []
                            MenuItem {
                                required property var modelData
                                readonly property bool target: airdrop.sendingTo === modelData.mac
                                icon: target && airdrop.sendFailed ? "exclamationmark_circle" : "paperplane"
                                label: modelData.name + (target && airdrop.sendStatus !== "" ? `  ·  ${airdrop.sendStatus}` : "")
                                opacity: airdrop.sending && !target ? 0.5 : 1
                                onClicked: target ? (airdrop.sending ? airdrop.cancelSend() : airdrop.dismissSend()) : airdrop.send(modelData.mac)
                            }
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "airdrop" && airdrop.usable
                            icon: "folder"
                            label: `Save to ${airdrop.dir.replace(Quickshell.env("HOME"), "~") || "…"}`
                            onClicked: airdrop.pickDir()
                        }

                        // Network
                        ColumnLayout {
                            visible: trayPill.shownPanel === "network"
                            Layout.margins: 6
                            spacing: 8
                            RowLayout {
                                spacing: 10
                                Icon { text: root.wifiIcon }
                                Label {
                                    Layout.fillWidth: true
                                    text: !root.wifiOn ? "Wi-Fi off" : root.wifiName === "" ? "Wi-Fi not connected" : `${root.wifiName}  ·  ${root.wifiSignal}%`
                                }
                            }
                            RowLayout {
                                spacing: 10
                                Icon { text: "arrow_left_right" }
                                Label { text: root.ethernet ? "Ethernet connected" : "Ethernet disconnected" }
                            }
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "network"
                            icon: "wifi"
                            label: root.wifiOn ? "Turn Wi-Fi off" : "Turn Wi-Fi on"
                            onClicked: root.run(`nmcli radio wifi ${root.wifiOn ? "off" : "on"}`)
                        }
                        Rectangle {
                            visible: trayPill.shownPanel === "network" && root.btAdapter !== null
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            implicitHeight: 1
                            color: "#26ffffff"
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "network" && root.btAdapter !== null
                            icon: ""
                            iconSource: "icons/bluetooth.svg"
                            label: root.btAdapter?.enabled ? "Turn Bluetooth off" : "Turn Bluetooth on"
                            onClicked: root.btAdapter.enabled = !root.btAdapter.enabled
                        }
                        // Paired devices: click to connect or disconnect
                        Repeater {
                            model: trayPill.shownPanel === "network" && (root.btAdapter?.enabled ?? false) ? root.btDevices : []
                            MenuItem {
                                required property var modelData
                                readonly property bool busy: modelData.state === BluetoothDeviceState.Connecting || modelData.state === BluetoothDeviceState.Disconnecting
                                icon: root.btIcon(modelData)
                                iconSource: icon === "" ? "icons/bluetooth.svg" : ""
                                label: modelData.name
                                    + (busy ? "  ·  …" : modelData.connected ? "  ·  Connected" : "")
                                    + (modelData.connected && modelData.batteryAvailable ? `  ·  ${Math.round(modelData.battery * 100)}%` : "")
                                opacity: modelData.connected || busy ? 1 : 0.6
                                onClicked: modelData.connected ? modelData.disconnect() : modelData.connect()
                            }
                        }

                        // Audio: volume slider (icon mutes), then outputs; click one to make it the default
                        RowLayout {
                            visible: trayPill.shownPanel === "audio"
                            Layout.margins: 6
                            Layout.leftMargin: 10
                            spacing: 10
                            IconButton {
                                text: root.volumeIcon
                                Layout.preferredWidth: 22
                                closesPanel: false
                                onClicked: if (root.sink?.audio) root.sink.audio.muted = !root.muted
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                height: 6
                                radius: 3
                                color: "#33ffffff"
                                Rectangle {
                                    width: parent.width * Math.min(1, root.volume)
                                    height: parent.height
                                    radius: 3
                                    color: root.muted ? "#66ffffff" : "white"
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -10 // easier to grab than the 6px track
                                    function set(x) { if (root.sink?.audio) root.sink.audio.volume = Math.max(0, Math.min(1, (x - 10) / (width - 20))); }
                                    onPressed: mouse => set(mouse.x)
                                    onPositionChanged: mouse => set(mouse.x)
                                    onWheel: wheel => { if (root.sink?.audio) root.sink.audio.volume = Math.max(0, Math.min(1, root.volume + (wheel.angleDelta.y > 0 ? 0.02 : -0.02))); }
                                }
                            }
                            Label {
                                Layout.preferredWidth: 34
                                horizontalAlignment: Text.AlignRight
                                text: Math.round(root.volume * 100)
                                color: root.muted ? "#99ffffff" : "white"
                            }
                        }
                        Rectangle {
                            visible: trayPill.shownPanel === "audio"
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            implicitHeight: 1
                            color: "#26ffffff"
                        }
                        Repeater {
                            model: trayPill.shownPanel === "audio" ? root.sinks : []
                            MenuItem {
                                required property var modelData
                                readonly property bool current: modelData === root.sink
                                icon: current ? "checkmark_alt" : ""
                                // The monitor's name for HDMI/DP audio; when two outputs share it, add the card (first word of the description)
                                readonly property string nick: modelData.nickname || modelData.description || modelData.name
                                label: nick + (root.sinks.filter(n => (n.nickname || n.description || n.name) === nick).length > 1 ? `  ·  ${modelData.description.split(" ")[0]}` : "")
                                onClicked: Pipewire.preferredDefaultAudioSink = modelData
                            }
                        }

                        // Notifications
                        RowLayout {
                            visible: trayPill.shownPanel === "notifications"
                            Layout.margins: 6
                            Label { text: "Notifications"; font.weight: Font.Medium; Layout.fillWidth: true }
                            Label {
                                text: "Clear all"
                                color: "#99ffffff"
                                visible: notifications.trackedNotifications.values.length > 0
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: [...notifications.trackedNotifications.values].forEach(n => n.dismiss())
                                }
                            }
                        }
                        Label {
                            visible: trayPill.shownPanel === "notifications" && notifications.trackedNotifications.values.length === 0
                            text: "No notifications"
                            color: "#99ffffff"
                            Layout.margins: 6
                        }
                        Repeater {
                            model: trayPill.shownPanel === "notifications" ? [...notifications.trackedNotifications.values].reverse().slice(0, 6) : []

                            Rectangle {
                                id: entry
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: entryBody.implicitHeight + 16
                                radius: 12
                                color: "#1affffff"

                                ColumnLayout {
                                    id: entryBody
                                    anchors { left: parent.left; right: dismiss.left; verticalCenter: parent.verticalCenter; leftMargin: 12 }
                                    spacing: 1
                                    Label { text: entry.modelData.appName; color: "#99ffffff"; font.pixelSize: 11 }
                                    Label { text: entry.modelData.summary; font.weight: Font.Medium; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Label {
                                        text: entry.modelData.body
                                        visible: text !== ""
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                        color: "#ccffffff"
                                    }
                                }
                                IconButton {
                                    id: dismiss
                                    anchors { right: parent.right; top: parent.top; margins: 8 }
                                    text: "xmark"
                                    font.pixelSize: 15
                                    onClicked: entry.modelData.dismiss()
                                }
                            }
                        }

                        // Power
                        // Keep awake: blocks idle lock and screen-off while on; the menu stays open to show the switch
                        Rectangle {
                            visible: trayPill.shownPanel === "power"
                            Layout.fillWidth: true
                            implicitHeight: 34
                            radius: 10
                            color: awakeArea.containsMouse ? "#22ffffff" : "transparent"

                            RowLayout {
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                spacing: 10
                                Image {
                                    // Framework7 has no cup, so these are custom SVGs in the same style
                                    source: root.keepAwake ? "icons/cup_fill.svg" : "icons/cup.svg"
                                    sourceSize: Qt.size(17, 17)
                                }
                                Label { text: "Keep awake"; Layout.fillWidth: true }
                                // Switch
                                Rectangle {
                                    implicitWidth: 34
                                    implicitHeight: 20
                                    radius: 10
                                    color: root.keepAwake ? "white" : "#33ffffff"
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Rectangle {
                                        width: 16
                                        height: 16
                                        radius: 8
                                        y: 2
                                        x: root.keepAwake ? parent.width - width - 2 : 2
                                        color: root.keepAwake ? "black" : "white"
                                        Behavior on x { SpringAnimation { spring: 5; damping: 0.4; epsilon: 0.25 } }
                                    }
                                }
                            }
                            MouseArea {
                                id: awakeArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.keepAwake = !root.keepAwake
                            }
                        }
                        Rectangle {
                            visible: trayPill.shownPanel === "power"
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            implicitHeight: 1
                            color: "#26ffffff"
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "power"; icon: "lock_fill"; label: "Lock"
                            onClicked: { root.panel = ""; root.locked = true; }
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "power"; icon: "moon_fill"; label: "Suspend"
                            onClicked: { root.panel = ""; root.run("systemctl suspend"); }
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "power"; icon: "square_arrow_right"; label: "Log out"
                            onClicked: Hyprland.dispatch("hl.dsp.exit()")
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "power"; icon: "arrow_clockwise"; label: "Restart"
                            onClicked: root.run("systemctl reboot")
                        }
                        MenuItem {
                            visible: trayPill.shownPanel === "power"; icon: "power"; label: "Shut down"
                            onClicked: root.run("systemctl poweroff")
                        }
                    }
                    }
                }
            }

            // Clicking outside the bar closes the launcher, media player or tray panel
            HyprlandFocusGrab {
                id: islandGrab
                windows: [bar]
                onCleared: { root.launcherOpen = false; root.mediaOpen = false; root.panel = ""; }
            }
            // Started after the launcher has taken keyboard focus; starting at once clears it straight away
            Timer {
                running: bar.launcher || bar.media || bar.panel !== ""
                interval: 50
                onTriggered: islandGrab.active = true
            }
            Connections {
                target: bar
                function release() { if (!bar.launcher && !bar.media && bar.panel === "") islandGrab.active = false; }
                function onLauncherChanged() { release(); }
                function onMediaChanged() { release(); }
                function onPanelChanged() { release(); }
            }
        }
    }
}
