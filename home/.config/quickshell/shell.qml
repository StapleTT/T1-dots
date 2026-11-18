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

    // ---- Look: monochrome, square boxes with 1px borders, monospace everywhere ----

    readonly property string mono: "JetBrainsMono Nerd Font"
    readonly property int barH: 30 // the bar is a flat strip across the top
    // The bar: translucent dark grey glass with grain. Must stay over 60% opaque for the layer rule to blur behind it
    readonly property color bg: "#c4161616" // ~77% opaque: dark grey even over bright wallpapers
    readonly property color edge: "#3a3a3a" // box borders
    readonly property color dim: "#80ffffff" // secondary text
    readonly property color accent: "white" // active workspace underline
    readonly property color glass: "#b80f0f0f" // floating boxes (panels, toasts, morphs); blurred behind by a layer rule
    // that only blurs pixels over 60% opaque, so keep this above that
    readonly property color glassLight: "#66141414" // desktop widgets, more see-through
    // Noise inside glass boxes: grain.png's opacity (its pixels average ~35% alpha). kitty tiles the same noise with this
    // strength baked in; both tiles come from make-grain.py, so change it there and rerun
    readonly property real boxGrain: 0.05

    // Nerd Font glyphs (in JetBrainsMono Nerd Font), by role
    readonly property var nf: {
        const g = {
            restart: 0xf021, ethernet: 0xf0200, prev: 0xf048, next: 0xf051, play: 0xf04b, pause: 0xf04c,
            check: 0xf00c, checkBox: 0xf14a, box: 0xf096, radioOn: 0xf192, radioOff: 0xf10c, left: 0xf053, right: 0xf054,
            phone: 0xf10b, clipboard: 0xf0ea, file: 0xf15c, alert: 0xf06a, folder: 0xf07b, gamepad: 0xf11b,
            terminal: 0xf120, headphones: 0xf025, keyboard: 0xf11c, lock: 0xf023, moon: 0xf186, music: 0xf001,
            send: 0xf1d8, user: 0xf2bd, image: 0xf03e, power: 0xf011, search: 0xf002, sliders: 0xf1de,
            volMute: 0xf0581, volLow: 0xf057f, volMid: 0xf0580, volHigh: 0xf057e, logout: 0xf08b,
            sunLow: 0xf00df, sunHigh: 0xf00e0, timer: 0xf017, wifi: 0xf05a9, wifiOff: 0xf05aa, wifiAlert: 0xf092b,
            close: 0xf00d, cpu: 0xf4bc, memory: 0xf035b, disk: 0xf02ca, gpu: 0xf2db, temp: 0xf2c9, down: 0xf019, up: 0xf093,
            bell: 0xf0f3, bellOff: 0xf1f6, bluetooth: 0xf293, package: 0xf03d7, calendar: 0xf073, nightLight: 0xf0594
        };
        for (const k in g) g[k] = String.fromCodePoint(g[k]);
        return g;
    }

    // Shared spring for all motion. Behaviors retarget it mid-flight keeping its velocity, so interrupted
    // animations carry their momentum instead of restarting. ~2.5% overshoot
    component Motion: SpringAnimation { spring: 5.5; damping: 0.4; epsilon: 0.5 }

    // A section of the bar strip; children are laid out in a row
    component Pill: Item {
        default property alias content: row.data
        property alias spacing: row.spacing
        height: root.barH
        width: row.implicitWidth + 20

        Behavior on width { Motion {} }

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 10
        }
    }

    // For text drawn straight on the wallpaper (lock screen)
    component Shadow: MultiEffect {
        shadowEnabled: true
        shadowColor: "#b0000000"
        shadowBlur: 0.8
        shadowVerticalOffset: 3
    }

    component Label: Text {
        color: "white"
        font { family: root.mono; pixelSize: 12 }
    }

    // Small caps-style section heading: "NETWORK"
    component Header: Label {
        color: "#d9ffffff"
        font { pixelSize: 11; bold: true; letterSpacing: 1 }
    }

    // Text is a glyph from root.nf
    component Icon: Text {
        color: "white"
        font { family: root.mono; pixelSize: 15 }
    }

    // Icon that reacts to clicks
    component IconButton: Icon {
        signal clicked()
        property bool closesPanel: true // set false on buttons that open a dropdown themselves
        opacity: area.containsMouse ? 0.6 : 1
        MouseArea {
            id: area
            // At least 26px square around the icon, so small icons (the tray chevron) are easy to hit
            anchors.centerIn: parent
            width: Math.max(parent.width + 8, 26)
            height: Math.max(parent.height + 8, 26)
            hoverEnabled: true
            onClicked: {
                if (parent.closesPanel) root.panel = "";
                parent.clicked();
            }
        }
    }

    // On/off: a small square, filled when on. Display only, the row or a MouseArea inside it handles clicks
    component Toggle: Item {
        property bool checked: false
        implicitWidth: 26
        implicitHeight: 20
        Rectangle {
            anchors.centerIn: parent
            width: 9
            height: 9
            color: parent.checked ? "white" : "transparent"
            border.width: 1
            border.color: parent.checked ? "white" : root.dim
            Behavior on color { ColorAnimation { duration: 100 } }
        }
    }

    // Level as a row of tick marks: ||||||||||||····
    component Ticks: Item {
        id: ticks
        property real level: 0 // 0..1
        property bool muted: false
        property int pitch: 5 // px per tick; sliders use sparser ticks
        property bool handle: false // taller tick at the level, for sliders
        readonly property int count: Math.max(1, Math.floor((width + pitch - 2) / pitch))
        implicitHeight: 12
        Rectangle {
            visible: ticks.handle
            x: Math.max(0, Math.min(1, ticks.level)) * (ticks.width - width)
            y: -2
            width: 3
            height: ticks.height + 4
            color: "white"
        }
        Repeater {
            model: ticks.count
            Rectangle {
                required property int index
                x: index * ticks.pitch
                width: 2
                height: ticks.height
                color: index < Math.round(Math.max(0, Math.min(1, ticks.level)) * ticks.count)
                    ? (ticks.muted ? "#66ffffff" : "white") : "#26ffffff"
            }
        }
    }

    // Corner brackets just outside a box
    component Corners: Item {
        anchors.fill: parent
        anchors.margins: -6
        Repeater {
            model: 4
            Item {
                id: corner
                required property int index
                width: 14
                height: 14
                x: index % 2 ? parent.width - width : 0
                y: index > 1 ? parent.height - height : 0
                Rectangle { width: 14; height: 1; y: corner.index > 1 ? 13 : 0; color: "#bfffffff" }
                Rectangle { width: 1; height: 14; x: corner.index % 2 ? 13 : 0; color: "#bfffffff" }
            }
        }
    }

    // Light noise inside a glass box (Hyprland's blur noise is applied to the downscaled blur, so it comes out as soft
    // blobs, not grain); first child of the box
    component Grain: Image {
        anchors.fill: parent
        anchors.margins: 1 // inside the border
        source: "grain.png"
        fillMode: Image.Tile
        smooth: false
        opacity: root.boxGrain
    }

    // Small boxed label sitting on a frame's border: CONTROL, MONOCHROME
    component Tag: Rectangle {
        property alias text: tagText.text
        width: tagText.implicitWidth + 12
        height: tagText.implicitHeight + 2
        color: "#1c1c1c"
        border.width: 1
        border.color: "#4d4d4d"
        Label {
            id: tagText
            anchors.centerIn: parent
            color: "#bfffffff"
            font { pixelSize: 9; bold: true; letterSpacing: 1 }
        }
    }

    // Control center tile: icon, LABEL and status, square switch top right (or centred in a compact tile).
    // Stacked tiles put the icon above the label, which sits at the bottom
    component CcTile: Rectangle {
        id: tile
        property string icon: ""
        property string iconSource: ""
        property string label
        property string sub: ""
        property bool checked: false
        property bool hasToggle: true
        property bool stacked: false
        signal toggled()
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: stacked ? 74 : 54
        color: tileArea.containsMouse ? "#12ffffff" : "transparent"
        MouseArea { id: tileArea; anchors.fill: parent; hoverEnabled: true; onClicked: tile.clicked() }
        Item {
            x: 10
            y: tile.stacked ? 12 : (tile.height - height) / 2
            width: 20
            height: 20
            Icon { anchors.centerIn: parent; text: tile.icon; visible: tile.iconSource === ""; font.pixelSize: 15 }
            Image { anchors.centerIn: parent; source: tile.iconSource; sourceSize: Qt.size(15, 15); visible: tile.iconSource !== "" }
        }
        Column {
            x: tile.stacked ? 10 : 40
            y: tile.stacked ? tile.height - height - 10 : (tile.height - height) / 2
            spacing: 2
            Header { text: tile.label; font.pixelSize: 10 }
            Label { text: tile.sub; color: root.dim; font.pixelSize: 9; visible: text !== "" }
        }
        Toggle {
            visible: tile.hasToggle
            checked: tile.checked
            anchors.right: parent.right
            y: tile.stacked ? 8 : (tile.height - height) / 2
            MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: tile.toggled() }
        }
    }

    // Row in a dropdown panel
    component MenuItem: Rectangle {
        required property string icon
        required property string label
        property string iconSource: "" // SVG instead of the font icon
        signal clicked()
        Layout.fillWidth: true
        implicitWidth: itemRow.implicitWidth + 20 // for the tray menu card, which sizes to its rows
        implicitHeight: 30
        color: itemArea.containsMouse ? "#1fffffff" : "transparent"
        RowLayout {
            id: itemRow
            anchors.fill: parent
            anchors.leftMargin: 10
            spacing: 10
            Icon { text: parent.parent.icon; visible: parent.parent.iconSource === ""; Layout.preferredWidth: 20; horizontalAlignment: Text.AlignHCenter }
            Image { source: parent.parent.iconSource; sourceSize: Qt.size(15, 15); visible: parent.parent.iconSource !== ""; Layout.preferredWidth: 20; fillMode: Image.Pad }
            Label { text: parent.parent.label; Layout.fillWidth: true }
        }
        MouseArea {
            id: itemArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: parent.clicked()
        }
    }

    // System monitor: CPU, memory, GPU meters, then storage, network and temperatures.
    // Used by the system panel and the desktop widget
    component SystemView: ColumnLayout {
        id: sysView
        property bool active: true // builds the lists only while shown
        spacing: 12

        Repeater {
            model: !sysView.active ? [] : [
                { icon: root.nf.cpu, name: "CPU", level: root.cpu, detail: [root.cpuModel.replace(/\s*\d+-Core Processor$/, ""),
                    ...root.temps.filter(t => t.name === "cpu").map(t => `${t.temp}°C`)].filter(d => d !== "").join("  ·  ") },
                { icon: root.nf.memory, name: "RAM", level: root.mem.used / root.mem.total,
                    detail: `${root.gib(root.mem.used)} / ${root.gib(root.mem.total)} GB used  ·  swap ${root.gib(root.mem.swapUsed)} / ${root.gib(root.mem.swapTotal)} GB` },
                ...(root.gpu ? [{ icon: root.nf.gpu, name: "GPU", level: root.gpu.util,
                    detail: `${root.gpu.name}  ·  VRAM ${(root.gpu.memUsed / 1024).toFixed(1)} / ${(root.gpu.memTotal / 1024).toFixed(1)} GB  ·  ${root.gpu.temp}°C` }] : [])
            ]

            ColumnLayout {
                id: meter
                required property var modelData
                Layout.fillWidth: true
                spacing: 4
                RowLayout {
                    spacing: 8
                    Icon { text: meter.modelData.icon; font.pixelSize: 13 }
                    Header { text: meter.modelData.name; Layout.fillWidth: true }
                    Label { text: `${Math.round(meter.modelData.level * 100)}%`; font { pixelSize: 14; bold: true } }
                }
                Ticks { Layout.fillWidth: true; level: meter.modelData.level }
                Label { text: meter.modelData.detail; color: root.dim; font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            RowLayout {
                spacing: 8
                Icon { text: root.nf.disk; font.pixelSize: 13 }
                Header { text: "STORAGE"; Layout.fillWidth: true }
                Label { text: `${root.mounts.length} mounts`; color: root.dim; font.pixelSize: 10 }
            }
            Repeater {
                model: sysView.active ? root.mounts : []
                ColumnLayout {
                    id: mount
                    required property var modelData
                    readonly property real share: modelData.used / Math.max(modelData.size, 1)
                    Layout.fillWidth: true
                    spacing: 3
                    RowLayout {
                        Label { text: mount.modelData.target; Layout.fillWidth: true; elide: Text.ElideRight }
                        Label {
                            text: `${Math.round(mount.share * 100)}%  ·  ${root.bytes(mount.modelData.used)} / ${root.bytes(mount.modelData.size)}`
                            color: root.dim
                            font.pixelSize: 10
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 2
                        color: "#26ffffff"
                        Rectangle { width: parent.width * mount.share; height: parent.height; color: mount.share > 0.9 ? "#ff6961" : "white" }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                spacing: 4
                RowLayout { spacing: 8; Icon { text: root.nf.wifi; font.pixelSize: 13 } Header { text: "NETWORK" } }
                Label { text: `${root.nf.down} ${root.bytes(root.net.rxRate)}/s`; color: root.dim; font.pixelSize: 11 }
                Label { text: `${root.nf.up} ${root.bytes(root.net.txRate)}/s`; color: root.dim; font.pixelSize: 11 }
                Label { text: root.net.dev; color: root.dim; font.pixelSize: 10 }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: 4
                RowLayout { spacing: 8; Icon { text: root.nf.temp; font.pixelSize: 13 } Header { text: "TEMPS" } }
                Flow {
                    Layout.fillWidth: true
                    spacing: 4
                    Repeater {
                        model: sysView.active ? root.temps : []
                        Rectangle {
                            required property var modelData
                            width: chip.implicitWidth + 10
                            height: chip.implicitHeight + 4
                            color: "transparent"
                            border.width: 1
                            border.color: "#2e2e2e"
                            Label { id: chip; anchors.centerIn: parent; text: `${parent.modelData.name} ${parent.modelData.temp}°`; color: "#bfffffff"; font.pixelSize: 10 }
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 28
            color: btopArea.containsMouse ? "#1fffffff" : "transparent"
            border.width: 1
            border.color: root.edge
            Label { anchors.centerIn: parent; text: `${root.nf.terminal}  open btop` }
            MouseArea {
                id: btopArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { root.panel = ""; Quickshell.execDetached(["kitty", "btop"]); }
            }
        }
    }


    // Month calendar: title with previous / next, week day initials, six weeks. Today is a white square, marked days
    // (root.marks) are underlined; when pickable, clicking a day picks it (outlined)
    component MonthGrid: ColumnLayout {
        id: month
        property int offset: 0 // months away from the current one
        property bool pickable: false
        property date picked: clock.date
        readonly property date shown: new Date(clock.date.getFullYear(), clock.date.getMonth() + offset, 1)
        // First cell: the week day the locale starts weeks on, on or before the 1st
        readonly property int lead: (shown.getDay() - Qt.locale().firstDayOfWeek % 7 + 7) % 7
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                text: Qt.formatDate(month.shown, "MMMM yyyy").toUpperCase()
                font { bold: true; letterSpacing: 1 }
            }
            IconButton { text: root.nf.left; font.pixelSize: 13; closesPanel: false; onClicked: month.offset-- }
            IconButton { text: root.nf.right; font.pixelSize: 13; closesPanel: false; onClicked: month.offset++ }
        }

        Grid {
            columns: 7
            Repeater {
                model: 7
                Label {
                    required property int index
                    width: 36
                    height: 24
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: Qt.locale().dayName((Qt.locale().firstDayOfWeek + index) % 7, Locale.NarrowFormat)
                    color: root.dim
                    font.pixelSize: 11
                }
            }
            Repeater {
                model: 42
                Item {
                    id: cell
                    required property int index
                    readonly property date day: new Date(month.shown.getFullYear(), month.shown.getMonth(), index - month.lead + 1)
                    readonly property bool inMonth: day.getMonth() === month.shown.getMonth()
                    readonly property bool today: day.toDateString() === clock.date.toDateString()
                    readonly property bool marked: root.marks.includes(root.dayKey(day))
                    width: 36
                    height: 32
                    Rectangle {
                        anchors.centerIn: parent
                        width: 28
                        height: 24
                        color: cell.today ? "white" : "transparent"
                        border.width: 1
                        border.color: cell.today ? "white" : month.pickable && cell.day.toDateString() === month.picked.toDateString() ? "#bfffffff" : "transparent"
                    }
                    Label {
                        anchors.centerIn: parent
                        text: cell.day.getDate()
                        color: cell.today ? "black" : cell.inMonth ? "white" : "#4dffffff"
                        font.bold: cell.today
                    }
                    Rectangle {
                        visible: cell.marked
                        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 6 }
                        width: 10
                        height: 2
                        color: cell.today ? "black" : "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: month.pickable
                        onClicked: {
                            month.picked = cell.day;
                            if (!cell.inMonth) month.offset += cell.index < 7 ? -1 : 1;
                        }
                    }
                }
            }
        }
    }

    function run(cmd) {
        Quickshell.execDetached(["sh", "-c", cmd]);
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // ---- User and host (top left, session card, lock screen) ----

    readonly property string userName: Quickshell.env("USER")
    property string hostName: ""
    FileView {
        path: "/etc/hostname"
        onLoaded: root.hostName = text().trim()
    }

    // ---- Network status and uptime, sampled every 2 s ----

    readonly property int interval: 2000
    property bool wifiOn: false
    property string wifiName: ""
    property int wifiSignal: 0
    property bool ethernet: false
    property int uptime: 0 // seconds
    readonly property string uptimeText: {
        const d = Math.floor(uptime / 86400), h = Math.floor(uptime % 86400 / 3600), m = Math.floor(uptime % 3600 / 60);
        return d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
    }

    Process {
        id: stats
        command: ["sh", "-c", `
            echo "radio $(nmcli radio wifi)"
            echo "wifi $(nmcli -t -f ACTIVE,SIGNAL,SSID dev wifi list --rescan no | grep -m1 '^yes')"
            echo "eth $(nmcli -t -f TYPE,STATE dev | grep -c '^ethernet:connected$')"
            echo "up $(cut -d. -f1 /proc/uptime)"
            echo "cpu $(head -1 /proc/stat | cut -d' ' -f2-)"
            echo "mem $(awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { printf "%s ", $2 }' /proc/meminfo)"`]
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
                root.uptime = parseInt(f.up) || 0;

                // CPU: busy share of the jiffies since the last sample (idle + iowait count as idle)
                const c = (f.cpu ?? "").split(/\s+/).map(Number);
                const total = c.reduce((x, y) => x + y, 0), idle = (c[3] ?? 0) + (c[4] ?? 0);
                if (root.cpuLast.total > 0 && total > root.cpuLast.total)
                    root.cpu = 1 - (idle - root.cpuLast.idle) / (total - root.cpuLast.total);
                root.cpuLast = { total, idle };
                // Memory in kB: MemTotal MemAvailable SwapTotal SwapFree
                const m = (f.mem ?? "").split(/\s+/).map(Number);
                if (m.length >= 4) root.mem = { total: m[0], used: m[0] - m[1], swapTotal: m[2], swapUsed: m[2] - m[3] };
            }
        }
    }

    // ---- CPU / memory (sampled with the network status) and the system panel ----

    property real cpu: 0 // 0..1
    property var cpuLast: ({ total: 0, idle: 0 })
    property var mem: ({ total: 1, used: 0, swapTotal: 0, swapUsed: 0 }) // kB
    function gib(kb) { return (kb / 1048576).toFixed(1); }
    function bytes(n) { // 1.1 KB, 288 B, 4.2 MB
        const u = ["B", "KB", "MB", "GB", "TB"];
        let i = 0;
        while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
        return `${i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
    }

    // Slower details, only while the system panel is open: GPU (nvidia-smi; absent while the VM has the card),
    // mounts, temperatures, network rate
    property string cpuModel: ""
    property var gpu: null // { name, util 0..1, memUsed, memTotal (MiB), temp }
    property var mounts: [] // { target, used, size } in bytes, one per device
    property var temps: [] // { name, temp }
    property var net: ({ dev: "", rx: 0, tx: 0, rxRate: 0, txRate: 0 })
    Process {
        id: sysInfo
        command: ["sh", "-c", `
            echo "model $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
            nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | sed 's/^/gpu /'
            df -B1 --output=source,target,used,size -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs | tail -n +2 | sed 's/^/df /'
            for h in /sys/class/hwmon/hwmon*; do [ -r $h/temp1_input ] && echo "temp $(cat $h/name) $(cat $h/temp1_input)"; done
            dev=$(ip route show default | awk 'NR == 1 { print $5 }')
            echo "net $dev $(awk -v d="$dev:" '$1 == d { print $2, $10 }' /proc/net/dev)"`]
        stdout: StdioCollector {
            onStreamFinished: {
                let gpu = null;
                const mounts = [], seen = new Set(), temps = [];
                for (const line of text.trim().split("\n")) {
                    const i = line.indexOf(" "), key = line.slice(0, i), v = line.slice(i + 1).trim();
                    const w = v.split(/\s+/);
                    if (key === "model") root.cpuModel = v;
                    else if (key === "gpu") {
                        const g = v.split(",").map(x => x.trim());
                        gpu = { name: g[0].replace(/^NVIDIA /, ""), util: +g[1] / 100, memUsed: +g[2], memTotal: +g[3], temp: +g[4] };
                    } else if (key === "df" && w[0].startsWith("/dev/") && !seen.has(w[0])) {
                        seen.add(w[0]); // btrfs subvolumes share a device
                        mounts.push({ target: w[1], used: +w[2], size: +w[3] });
                    } else if (key === "temp") {
                        temps.push({ name: w[0] === "k10temp" || w[0] === "coretemp" ? "cpu" : w[0], temp: Math.round(+w[1] / 1000) });
                    } else if (key === "net" && w.length >= 3) {
                        const rx = +w[1], tx = +w[2], o = root.net, s = root.interval / 1000;
                        root.net = { dev: w[0], rx, tx, rxRate: o.dev === w[0] && o.rx ? (rx - o.rx) / s : 0, txRate: o.dev === w[0] && o.tx ? (tx - o.tx) / s : 0 };
                    }
                }
                root.gpu = gpu;
                root.mounts = mounts;
                root.temps = temps;
            }
        }
    }
    Timer {
        interval: root.interval
        running: root.panel === "system" || (root.desktopVisible && root.showSysWidget)
        repeat: true
        triggeredOnStart: true
        onTriggered: sysInfo.running = true
    }

    Timer {
        interval: root.interval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: stats.running = true
    }

    // ---- Wi-Fi networks for the Wi-Fi panel, rescanned every 10 s while it's open ----

    property var wifiNetworks: [] // { ssid, signal, secure, active, known }, connected first, then by signal
    readonly property bool wifiScan: panel === "network" && wifiOn
    property string wifiPrompt: "" // SSID whose password field is open
    property string wifiConnecting: ""
    property string wifiError: ""

    Process {
        id: wifiList
        // Saved Wi-Fi profiles, then visible networks; nmcli -t escapes ':' inside fields as '\:'
        command: ["sh", "-c", `
            nmcli -t -f NAME,TYPE con show | sed -n 's/^/known /; s/:802-11-wireless$//p'
            nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID dev wifi list --rescan yes | sed 's/^/net /'`]
        stdout: StdioCollector {
            onStreamFinished: {
                const known = new Set(), nets = new Map();
                for (const line of text.split("\n")) {
                    const f = line.slice(line.indexOf(" ") + 1).replace(/\\:/g, "\x01").split(":").map(x => x.replace(/\x01/g, ":"));
                    if (line.startsWith("known ")) known.add(f[0]);
                    if (!line.startsWith("net ") || f[3] === "") continue; // hidden networks have no SSID
                    const n = { ssid: f[3], signal: parseInt(f[1]) || 0, secure: f[2] !== "" && f[2] !== "--", active: f[0] === "*" };
                    const old = nets.get(n.ssid); // one row per SSID, however many access points
                    if (!old || n.active || (!old.active && n.signal > old.signal)) nets.set(n.ssid, n);
                }
                root.wifiNetworks = [...nets.values()].map(n => Object.assign(n, { known: known.has(n.ssid) }))
                    .sort((a, b) => b.active - a.active || b.signal - a.signal);
            }
        }
    }
    Timer {
        interval: 10000
        running: root.wifiScan
        repeat: true
        triggeredOnStart: true
        onTriggered: wifiList.running = true
    }

    // Arguments go to nmcli directly, never through a shell: SSIDs are chosen by whoever runs the network
    Process {
        id: wifiConnect
        property var network: null
        stderr: StdioCollector { id: wifiConnectErr }
        onExited: code => {
            root.wifiConnecting = "";
            if (code === 0) {
                root.wifiPrompt = "";
                root.wifiError = "";
            } else {
                // A saved profile with a stale password fails too, so offer the password field
                root.wifiError = network.secure ? "Couldn't connect. Check the password." : "Couldn't connect.";
                if (network.secure) root.wifiPrompt = network.ssid;
            }
            stats.running = true;
            wifiList.running = true;
        }
    }
    function wifiJoin(network, password) {
        if (wifiConnect.running) return;
        wifiConnecting = network.ssid;
        wifiError = "";
        wifiConnect.network = network;
        wifiConnect.command = password !== undefined ? ["nmcli", "dev", root.nf.wifi, "connect", network.ssid, "password", password]
            : network.known ? ["nmcli", "con", "up", "id", network.ssid]
            : ["nmcli", "dev", root.nf.wifi, "connect", network.ssid];
        wifiConnect.running = true;
    }

    // Bluetooth (BlueZ): paired devices, connected ones first; the tray shows an icon only while one is connected
    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property var btDevices: Bluetooth.devices.values.filter(d => d.paired).sort((a, b) => b.connected - a.connected)
    readonly property bool btConnected: btDevices.some(d => d.connected)
    // Unpaired devices seen while scanning; nameless ones (just an address) are left out
    readonly property var btNearby: Bluetooth.devices.values.filter(d => !d.paired && d.deviceName !== "")
    // Scan only while a Bluetooth panel is open
    readonly property bool btScan: panel === "bluetooth" && (btAdapter?.enabled ?? false)
    onBtScanChanged: if (btAdapter) btAdapter.discovering = btScan
    // Pair, then connect once BlueZ reports it paired. No pairing agent is registered, so devices that need a PIN
    // (keyboards) still need bluetoothctl
    property var btPairing: null
    function btPair(device) {
        btPairing = device;
        device.trusted = true;
        device.pair();
    }
    Connections {
        target: root.btPairing
        function onPairedChanged() {
            if (!root.btPairing.paired) return;
            root.btPairing.connect();
            root.btPairing = null;
        }
    }
    // Framework7 has no Bluetooth glyph, so "" means the custom icons/bluetooth.svg
    function btIcon(device) {
        const icon = device.icon;
        return icon.startsWith("audio") ? root.nf.headphones : icon === "input-gaming" ? root.nf.gamepad
            : icon === "input-keyboard" ? root.nf.keyboard : icon === "phone" ? root.nf.phone : "";
    }

    // Icon file for an app ID, for the overview's window badges. Theme lookups run once per
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

    readonly property string wifiIcon: !wifiOn ? root.nf.wifiOff : wifiName === "" ? root.nf.wifiAlert : root.nf.wifi

    // ---- Media: the playing player, else the last one that played, else the first one ----

    property var lastPlayer: null
    readonly property var player: Mpris.players.values.find(p => p.isPlaying)
        ?? (Mpris.players.values.includes(lastPlayer) ? lastPlayer : Mpris.players.values[0]) ?? null
    onPlayerChanged: {
        if (!player) mediaOpen = false
        else if (player.isPlaying) lastPlayer = player
    }

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
    readonly property string volumeIcon: muted || volume === 0 ? root.nf.volMute
        : volume < 0.34 ? root.nf.volLow : volume < 0.67 ? root.nf.volMid : root.nf.volHigh
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
    function setBrightness(v) {
        if (brightness < 0) return;
        brightness = Math.max(0, Math.min(100, Math.round(v)));
        ddcTimer.restart();
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
    // Days marked on the desktop calendar ("yyyy-MM-dd"), kept in a state file
    property var marks: []
    function dayKey(d) { return Qt.formatDate(d, "yyyy-MM-dd"); }
    function toggleMark(d) {
        const k = dayKey(d);
        marks = marks.includes(k) ? marks.filter(m => m !== k) : [...marks, k].sort();
        marksFile.setText(JSON.stringify(marks));
    }
    FileView {
        id: marksFile
        path: `${Quickshell.env("HOME")}/.local/state/quickshell/marks.json`
        printErrors: false // missing until a day is marked
        onLoaded: { try { root.marks = JSON.parse(text()); } catch (e) { root.marks = []; } }
    }

    // Control center switches
    property bool dnd: false // Do Not Disturb: no popups (critical ones still show); the list still fills
    property bool nightLight: false
    property bool showSysWidget: true // the system monitor on the desktop
    // Night light: hyprsunset runs while it's on and is stopped when switched off
    Process {
        running: root.nightLight
        command: ["hyprsunset", "-t", "4000"]
    }

    // MPRIS doesn't push position updates, so ask for them while playing (the bar shows the position)
    Timer {
        running: root.player?.isPlaying ?? false
        interval: 1000
        repeat: true
        onTriggered: root.player.positionChanged()
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
                    spacing: 0
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: "#60000000"
                        shadowBlur: 0.6
                        shadowVerticalOffset: 2
                    }

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: `[ ${Qt.formatDateTime(clock.date, "dddd d MMMM")} ]`
                        color: "#d9ffffff"
                        font { pixelSize: 20 }
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDateTime(clock.date, "h:mm AP").replace(/\s*[AP]M$/i, "") // 12-hour like the bar, without AM/PM
                        font { pixelSize: 140; weight: Font.Bold }
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

                // Password, near the bottom centre: a prompt line in a box, like the bar's panels
                Rectangle {
                    id: passwordPill
                    property real shake: 0
                    x: (parent.width - width) / 2 + shake
                    y: parent.height - height - 140
                    width: 380
                    height: 40
                    color: "#e60d0d0d"
                    border.width: 1
                    border.color: lockInput.activeFocus ? "#8a8a8a" : root.edge
                    opacity: root.authenticating ? 0.6 : 1
                    Corners {}

                    Label {
                        id: lockPrompt
                        anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                        text: `${root.userName}@${root.hostName} ${root.nf.lock}`
                        color: root.dim
                        font.pixelSize: 14
                    }

                    TextInput {
                        id: lockInput
                        anchors { left: lockPrompt.right; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 10; rightMargin: 14 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: "white"
                        font { family: root.mono; pixelSize: 14; letterSpacing: 1 }
                        echoMode: TextInput.Password
                        passwordCharacter: "*"
                        enabled: !root.authenticating
                        clip: true
                        focus: true
                        // Block caret, shown while empty too, like a terminal
                        cursorDelegate: Rectangle { width: 8; color: "white"; visible: lockInput.cursorVisible }
                        text: root.lockPassword
                        onTextChanged: root.lockPassword = text
                        Component.onCompleted: forceActiveFocus()

                        Label {
                            anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                            visible: lockInput.text === ""
                            text: root.authenticating ? "checking…" : "password"
                            color: "#59ffffff"
                            font.pixelSize: 14
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
    property string panel: "" // "user", "system", "control", "apps", "airdrop", "audio", "network", "bluetooth" or ""
    property var panelBar: null

    // AirDrop via omdrop; the logic lives in AirDrop.qml, the icon and dropdown are in the tray pill
    AirDrop {
        id: airdrop
        panelOpen: root.panel === "airdrop"
        // Steps aside for the file chooser and comes back on the same bar
        onPanelWanted: open => root.panel = open ? "airdrop" : ""
    }
    // Tray app menu shown in the card while the tray pill's apps are open: [app menu, submenu, ...]; empty shows no card
    property var trayMenus: []
    onPanelChanged: {
        trayMenus = [];
        wifiPrompt = "";
        wifiError = "";
    }

    NotificationServer {
        id: notifications
        keepOnReload: true
        actionsSupported: true
        bodySupported: true
        bodyMarkupSupported: false
        imageSupported: false

        onNotification: n => {
            n.tracked = true;
            if (root.dnd && n.urgency !== NotificationUrgency.Critical) return;
            root.toasts = [...root.toasts, n];
            n.closed.connect(() => root.toasts = root.toasts.filter(t => t !== n));
        }
    }

    // Toasts appear under the tray on the focused monitor
    PanelWindow {
        screen: Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor) ?? Quickshell.screens[0]
        visible: root.toasts.length > 0 && (root.panel === "" || (root.panel === "apps" && root.trayMenus.length === 0)) // they'd cover the dropdown card
        anchors { top: true; right: true }
        margins { top: root.barH + 4; right: 6 }
        // Place from the screen edge: respecting the bar's exclusive zone would push the toasts down another 44px
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell-toasts"
        implicitWidth: 400
        implicitHeight: toastColumn.implicitHeight + 30
        color: "transparent"
        mask: Region { item: toastColumn }

        Column {
            id: toastColumn
            x: 10
            y: 6 // same gap below the bar as the panel card
            width: 380
            spacing: 8

            Repeater {
                model: root.toasts

                Rectangle {
                    id: toast
                    required property var modelData
                    width: toastColumn.width
                    height: toastBody.implicitHeight + 20
                    color: root.glass
                    border.width: 1
                    border.color: root.edge
                    Grain {}

                    HoverHandler { id: toastHover }

                    // Critical notifications stay until clicked; the others wait while hovered
                    Timer {
                        running: toast.modelData.urgency !== NotificationUrgency.Critical && !toastHover.hovered
                        interval: toast.modelData.expireTimeout > 0 ? toast.modelData.expireTimeout : 5000
                        onTriggered: root.toasts = root.toasts.filter(t => t !== toast.modelData)
                    }

                    ColumnLayout {
                        id: toastBody
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14; rightMargin: 34 }
                        spacing: 2
                        Label { text: toast.modelData.appName.toUpperCase(); color: root.dim; font { pixelSize: 10; letterSpacing: 1 } }
                        Label { text: toast.modelData.summary; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
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

                    // Shown on hover: dismiss, which also removes it from the control center list
                    IconButton {
                        visible: toastHover.hovered
                        anchors { right: parent.right; top: parent.top; margins: 12 }
                        text: root.nf.close
                        font.pixelSize: 13
                        closesPanel: false
                        onClicked: toast.modelData.dismiss()
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
        Behavior on shown { Motion { epsilon: 0.002 } }

        screen: Quickshell.screens.find(s => s.name === monitor?.name) ?? null
        // Threshold, not > 0: the spring dips just below 0 on close and must not remap the window
        visible: root.overviewOpen || shown > 0.01
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
                            font.bold: tile.current
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

    // ---- Desktop widgets: calendar and system monitor on the wallpaper, under the windows ----

    // Some monitor shows its desktop (an empty workspace), so the widgets are shown there
    readonly property bool desktopVisible: Hyprland.monitors.values.some(m => (m.activeWorkspace?.toplevels.values.length ?? 1) === 0)

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: desk
            required property var modelData
            readonly property var monitor: Hyprland.monitorFor(modelData)
            screen: modelData
            // Only while this monitor's current workspace has no windows
            visible: (monitor?.activeWorkspace?.toplevels.values.length ?? 1) === 0
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Normal // stays below the bar
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.namespace: "quickshell:desktop" // blurred behind by a layer rule in hyprland.lua
            color: "transparent"
            mask: Region { item: calWidget; Region { item: sysWidget } }

            // Calendar, top left: the month, and the picked day with its mark
            Rectangle {
                id: calWidget
                x: 24
                y: 24
                width: calRow.implicitWidth + 36
                height: calRow.implicitHeight + 36
                color: root.glassLight
                border.width: 1
                border.color: root.edge
                Grain {}
                Corners {}

                RowLayout {
                    id: calRow
                    x: 18
                    y: 18
                    spacing: 18

                    MonthGrid {
                        id: deskMonth
                        pickable: true
                        Layout.alignment: Qt.AlignTop
                    }
                    Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: "#262626" }
                    ColumnLayout {
                        id: dayPane
                        readonly property date today: new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate())
                        readonly property date pickedDay: new Date(deskMonth.picked.getFullYear(), deskMonth.picked.getMonth(), deskMonth.picked.getDate())
                        readonly property int fromToday: Math.round((pickedDay - today) / 86400000)
                        readonly property bool marked: root.marks.includes(root.dayKey(deskMonth.picked))
                        readonly property var monthMarks: root.marks.filter(m => m.startsWith(Qt.formatDate(deskMonth.shown, "yyyy-MM-")))
                        Layout.preferredWidth: 210
                        Layout.fillHeight: true
                        spacing: 4

                        Label { text: Qt.formatDate(deskMonth.picked, "dddd d MMMM"); font.bold: true }
                        Label {
                            text: dayPane.fromToday === 0 ? "today" : dayPane.fromToday === 1 ? "tomorrow" : dayPane.fromToday === -1 ? "yesterday"
                                : dayPane.fromToday > 0 ? `in ${dayPane.fromToday} days` : `${-dayPane.fromToday} days ago`
                            color: root.dim
                            font.pixelSize: 10
                        }
                        Item { Layout.fillHeight: true }
                        Header { text: "MARKED"; color: root.dim; font.pixelSize: 10 }
                        Label {
                            Layout.fillWidth: true
                            text: dayPane.monthMarks.length === 0 ? "nothing this month"
                                : dayPane.monthMarks.map(m => +m.slice(8)).join(" · ")
                            color: dayPane.monthMarks.length === 0 ? "#59ffffff" : "white"
                            wrapMode: Text.Wrap
                        }
                        Item { Layout.fillHeight: true }
                        // Mark / unmark the picked day
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 28
                            color: markArea.containsMouse ? "#1fffffff" : "transparent"
                            border.width: 1
                            border.color: root.edge
                            RowLayout {
                                anchors { fill: parent; leftMargin: 4; rightMargin: 10 }
                                Toggle { checked: dayPane.marked }
                                Label { text: dayPane.marked ? "marked" : "mark this day"; Layout.fillWidth: true }
                            }
                            MouseArea {
                                id: markArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.toggleMark(deskMonth.picked)
                            }
                        }
                    }
                }
            }

            // System monitor, top right
            Rectangle {
                id: sysWidget
                visible: root.showSysWidget
                x: parent.width - width - 24
                y: 24
                width: 420
                height: sysCol.implicitHeight + 36
                color: root.glassLight
                border.width: 1
                border.color: root.edge
                Grain {}
                Corners {}

                ColumnLayout {
                    id: sysCol
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
                    spacing: 14
                    RowLayout {
                        spacing: 10
                        Icon { text: root.nf.cpu }
                        Label { text: "SYSTEM"; Layout.fillWidth: true; font { pixelSize: 15; bold: true; letterSpacing: 2 } }
                        Label { text: `live · ${root.interval / 1000}s`; color: root.dim; font.pixelSize: 10 }
                    }
                    SystemView {
                        Layout.fillWidth: true
                        active: root.desktopVisible && root.showSysWidget
                    }
                }
            }
        }
    }

    // ---- Bar ----

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            anchors { top: true; left: true; right: true }
            // Fixed height with room for the open launcher and panels; resizing the surface makes everything flicker.
            // The mask keeps the empty part click-through.
            implicitHeight: 1000
            exclusiveZone: root.barH // Hyprland gaps_out adds the gap below
            color: "transparent"
            // OnDemand rather than Exclusive: an exclusive layer stops the focus grab seeing clicks outside
            // Password prompts take the keyboard exclusively so the password can't land in another window
            WlrLayershell.keyboardFocus: auth ? WlrKeyboardFocus.Exclusive : launcher || (panel === "network" && root.wifiPrompt !== "") ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
            // Only the strip and open boxes take clicks; the rest of the surface passes through.
            mask: Region {
                item: strip
                Region { item: workspacesPill }
                Region { item: logoPill }
                Region { item: closeArea }
                Region { item: titlePill }
                Region { item: rightPills }
                Region { item: panelCard }
            }

            readonly property var monitor: Hyprland.monitorFor(modelData)
            // Fullscreen windows cover the Top layer, so the volume/brightness popup lifts the bar to Overlay until it
            // has faded out. The rest of the bar stays hidden the whole time a window is fullscreen (it's covered anyway),
            // so nothing flashes while the layer changes back
            readonly property bool fullscreen: monitor?.activeWorkspace?.hasFullscreen ?? false
            readonly property bool overFullscreen: fullscreen && (titlePill.osd || osdBody.visible)
            WlrLayershell.layer: overFullscreen ? WlrLayer.Overlay : WlrLayer.Top

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

            // Where a tray icon was clicked; its menu's left edge lines up with it
            property real trayMenuX: 0

            function toggle(name) {
                root.panel = panel === name ? "" : name;
                root.panelBar = bar;
                root.launcherOpen = false;
                root.mediaOpen = false;
            }

            // The bar: a flat strip across the top with a hairline underneath
            Rectangle {
                id: strip
                width: parent.width
                height: root.barH
                color: root.bg
                visible: !bar.fullscreen
                Grain {}
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#1fffffff" }
            }

            // While a dropdown or the launcher is open, clicking empty bar space closes it (the focus grab doesn't see clicks on the bar)
            MouseArea {
                id: closeArea
                width: parent.width
                height: bar.panel !== "" || bar.launcher || bar.media ? parent.height : 0
                onClicked: { root.panel = ""; root.launcherOpen = false; root.mediaOpen = false; }
            }

            // Top left: user@host, which opens the launcher
            Pill {
                id: logoPill
                visible: !bar.fullscreen
                Label {
                    textFormat: Text.StyledText
                    text: `${root.userName}<font color="#80ffffff">@</font>${root.hostName}`
                    font.bold: true
                    opacity: userArea.containsMouse ? 0.6 : 1
                    MouseArea {
                        id: userArea
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        onClicked: root.toggleLauncher("apps")
                    }
                }
            }

            // Then workspaces on this monitor
            Row {
                id: workspacesPill
                x: logoPill.width - 4
                height: root.barH
                visible: !bar.fullscreen

                Repeater {
                    // Cells 1..highest workspace on this monitor, so gaps show as empty cells and position = number.
                    // A count (not the workspace list) keeps existing cells alive when workspaces come and go.
                    model: Math.max(0, ...Hyprland.workspaces.values.filter(w => w.id > 0 && w.monitor === bar.monitor).map(w => w.id))

                    // A full-height square per workspace: the active one is highlighted top to bottom with a short
                    // accent underline; numbers are white with windows, dim when empty
                    Rectangle {
                        id: ws
                        required property int index
                        readonly property int wsId: index + 1
                        readonly property var workspace: Hyprland.workspaces.values.find(w => w.id === wsId) ?? null
                        readonly property bool active: bar.monitor?.activeWorkspace?.id === wsId
                        readonly property bool occupied: (workspace?.toplevels.values.length ?? 0) > 0
                        width: root.barH
                        height: root.barH
                        color: active ? "#1fffffff" : wsArea.containsMouse ? "#0fffffff" : "transparent"

                        Label {
                            anchors.centerIn: parent
                            text: ws.wsId
                            color: ws.active || ws.occupied ? "white" : "#59ffffff"
                            font.bold: ws.active
                        }
                        Rectangle {
                            visible: ws.active
                            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
                            width: 12
                            height: 2
                            color: root.accent
                        }

                        // Click to switch (workspace.activate() sends legacy dispatch syntax, which the Lua config rejects);
                        // middle-click closes every window on it (politely, like SUPER+Q, so apps can ask to save)
                        MouseArea {
                            id: wsArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onClicked: mouse => {
                                root.panel = "";
                                if (mouse.button === Qt.MiddleButton) {
                                    for (const t of ws.workspace?.toplevels.values ?? [])
                                        Hyprland.dispatch(`hl.dsp.window.close({ window = "address:0x${t.address}" })`);
                                } else {
                                    Hyprland.dispatch(`hl.dsp.focus({ workspace = ${ws.wsId} })`);
                                }
                            }
                        }
                    }
                }
            }

            // Top middle: the window title as [ title ]; it morphs into the launcher, media player, password prompt and
            // volume/brightness popup
            // 0..1 while the title shrinks in or out (no window title, nothing morphed)
            property real titleAmount: titlePill.morphed || titlePill.title !== "" ? 1 : 0
            Behavior on titleAmount { Motion { epsilon: 0.01 } }
            readonly property real titleShown: Math.max(0, titleAmount)
            readonly property real groupLeft: (width - titlePill.width * titleShown) / 2



            // Right-click in the middle of the strip opens the launcher, even with no window title showing
            MouseArea {
                visible: !bar.fullscreen
                x: (parent.width - width) / 2
                width: 640
                height: root.barH
                acceptedButtons: Qt.RightButton
                onClicked: root.toggleLauncher("apps")
            }

            // Shadow under the floating launcher, so it stands out from the windows
            RectangularShadow {
                x: titlePill.x
                y: titlePill.y
                width: titlePill.width
                height: titlePill.height
                offset.y: 14
                blur: 56
                // At most 50% opaque: Hyprland's layer blur (ignore_alpha 0.6) must not pick up the shadow
                color: "#80000000"
                opacity: titlePill.open ? 1 : 0
                visible: opacity > 0 && titlePill.visible
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            Rectangle {
                id: titlePill
                readonly property string title: ToplevelManager.activeToplevel?.title ?? ""
                // Last non-empty title, kept while the title shrinks away
                property string shownTitle: title
                onTitleChanged: if (title !== "") shownTitle = title
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

                // Scaled about its centre, so shift it to stay centred in its shrinking slot
                x: bar.groupLeft + shake - width * (1 - bar.titleShown) / 2
                // The launcher drops from the strip to the upper middle of the screen (Spotlight style); the rest hang from the top
                y: open ? Math.round(bar.screen.height * 0.22) : 0
                Behavior on y { Motion {} }
                scale: bar.titleShown
                opacity: Math.min(1, bar.titleShown)
                visible: (!bar.fullscreen || bar.overFullscreen) && bar.titleShown > 0.01
                width: auth ? 460 : open ? 680 : media ? 520 : osd ? 340 : Math.min(titleLabel.implicitWidth, 600) + 20
                height: auth ? authBody.implicitHeight + 36 : open ? 40 + (resultCount > 0 ? resultCount * 32 + 8 : 0) : media ? 132 : root.barH
                // Text in the strip; morphed it hangs from the top as a bordered box (the OSD stays in the strip, boxed only
                // over a fullscreen window)
                color: (!morphed || osd) && !bar.overFullscreen ? "transparent" : root.glass
                border.width: 1
                border.color: (morphed && !osd) || bar.overFullscreen ? root.edge : "transparent"

                // Glass frame while morphed (the content clips itself below); brackets on the floating launcher
                Grain { visible: titlePill.morphed && !titlePill.osd }
                Corners { visible: titlePill.open }

                // Springy resize for the morph
                Behavior on width { Motion {} }
                Behavior on height { Motion {} }


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

                // Right-clicking the title opens the launcher (like SUPER+Space);
                // once morphed, swallow clicks on empty launcher space so they don't reach the close area underneath
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: titlePill.morphed ? Qt.LeftButton : Qt.RightButton
                    onClicked: if (!titlePill.morphed) root.toggleLauncher("apps")
                }

                Label {
                    id: titleLabel
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, 600)
                    text: `[ ${titlePill.shownTitle} ]`
                    elide: Text.ElideMiddle
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
                    Behavior on shownLevel { Motion { epsilon: 0.002 } }
                    // Laid out at the popup's final size and centred, so the morph from a wide title doesn't stretch it
                    anchors.centerIn: parent
                    width: 340 - 24
                    height: root.barH
                    spacing: 10
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
                        text: !osdBody.isVolume ? (osdBody.level < 0.5 ? root.nf.sunLow : root.nf.sunHigh)
                            : root.volumeIcon
                    }
                    Ticks {
                        Layout.fillWidth: true
                        level: osdBody.shownLevel
                        muted: osdBody.muted
                    }
                    Label {
                        text: `[ ${osdBody.isVolume ? "VOL" : "BRT"} ${String(Math.round(osdBody.level * 100)).padStart(3)}% ]`
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
                            Icon { text: root.nf.lock; font.pixelSize: 22; Layout.alignment: Qt.AlignTop }
                            ColumnLayout {
                                spacing: 2
                                Header { text: "AUTHENTICATION REQUIRED" }
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
                            implicitHeight: 34
                            color: "transparent"
                            border.width: 1
                            border.color: password.activeFocus ? "#8a8a8a" : root.edge

                            TextInput {
                                id: password
                                anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                                verticalAlignment: TextInput.AlignVCenter
                                color: "white"
                                font { family: root.mono; pixelSize: 13 }
                                echoMode: polkit.flow?.responseVisible ? TextInput.Normal : TextInput.Password
                                passwordCharacter: "*"
                                cursorDelegate: Rectangle { width: 7; color: "white"; visible: password.cursorVisible }
                                enabled: polkit.flow?.isResponseRequired ?? false
                                clip: true

                                Label {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: password.text === ""
                                    // polkit's prompt is usually "Password: "
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    text: (polkit.flow?.inputPrompt || "Password").replace(/:\s*$/, "").toLowerCase()
                                    color: "#66ffffff"
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
                                implicitHeight: 30
                                color: cancelArea.containsMouse ? "#1fffffff" : "transparent"
                                border.width: 1
                                border.color: root.edge
                                Label { anchors.centerIn: parent; text: "cancel" }
                                MouseArea {
                                    id: cancelArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: polkit.flow?.cancelAuthenticationRequest()
                                }
                            }
                            Rectangle {
                                implicitWidth: 120
                                implicitHeight: 30
                                color: "white"
                                opacity: authArea.containsMouse ? 0.85 : 1
                                Label { anchors.centerIn: parent; text: "authenticate"; color: "black"; font.bold: true }
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
                                text: root.nf.music
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
                                    color: "#33ffffff"
                                    Rectangle {
                                        width: parent.width * Math.min(1, (root.player?.position ?? 0) / Math.max(progress.length, 1))
                                        height: parent.height
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
                                    text: root.nf.prev
                                    font.pixelSize: 24
                                    enabled: root.player?.canGoPrevious ?? false
                                    opacity: enabled ? 1 : 0.4
                                    onClicked: root.player.previous()
                                }
                                IconButton {
                                    text: root.player?.isPlaying ? root.nf.pause : root.nf.play
                                    font.pixelSize: 30
                                    enabled: root.player?.canTogglePlaying ?? false
                                    onClicked: root.player.togglePlaying()
                                }
                                IconButton {
                                    text: root.nf.next
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
                        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 14; rightMargin: 14 }
                        height: 40
                        spacing: 10
                        Label { text: titlePill.clipMode ? "clip ❯" : "run ❯"; color: "#99ffffff"; font { pixelSize: 13; bold: true } }
                        TextInput {
                            id: search
                            Layout.fillWidth: true
                            color: "white"
                            selectionColor: "#55ffffff"
                            font { family: root.mono; pixelSize: 13 }
                            clip: true
                            cursorDelegate: Rectangle { width: 7; color: "white"; visible: search.cursorVisible }

                            Label {
                                x: 12
                                visible: search.text === ""
                                text: titlePill.clipMode ? "search clipboard history" : "search apps or type a command"
                                color: "#59ffffff"
                                font.pixelSize: 13
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
                                height: 32
                                color: titlePill.selected === index ? "#262626" : "transparent"
                                // Selection marker on the left edge
                                Rectangle { width: 2; height: parent.height; color: "white"; visible: titlePill.selected === result.index }

                                RowLayout {
                                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                    spacing: 12
                                    IconImage {
                                        visible: result.app !== null
                                        source: result.app ? Quickshell.iconPath(result.app.icon, "application-x-executable") : ""
                                        implicitSize: 18
                                    }
                                    Icon {
                                        visible: result.app === null
                                        text: result.clipEntry ? (result.clipEntry.image ? root.nf.image : root.nf.file) : root.nf.terminal
                                        Layout.preferredWidth: 18
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

            // Top right: tray apps, media, date and time, Wi-Fi, volume, control center, session
            Row {
                id: rightPills
                visible: !bar.fullscreen
                anchors.right: parent.right
                spacing: 0

                // System tray; its panels open in the card in the top right corner
                Item {
                    id: trayPill
                    // No spring here: the app icons' own spring drives the width, so the content never lags the strip
                    width: trayIcons.implicitWidth + 20
                    height: root.barH

                    RowLayout {
                        id: trayIcons
                        anchors.centerIn: parent
                        height: root.barH
                        spacing: 16

                        // Tray icons from other apps, hidden behind the chevron; opening springs the pill out to the left.
                        // Left click opens the app (or its menu if that's all it has), right click its menu in the card,
                        // middle click its secondary action
                        Item {
                            id: trayApps
                            property real amount: bar.panel === "apps" ? 1 : 0
                            Behavior on amount { Motion { epsilon: 0.01 } }
                            // Grows by the icons plus the row spacing, so the spacing doesn't pop in when it appears
                            readonly property real slot: Math.max(0, amount) * (appIcons.implicitWidth + trayIcons.spacing)
                            visible: slot >= trayIcons.spacing
                            Layout.preferredWidth: slot - trayIcons.spacing
                            Layout.fillHeight: true
                            opacity: Math.min(1, Math.max(0, amount))
                            clip: true

                            Row {
                                id: appIcons
                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                spacing: 12

                                Repeater {
                                    model: SystemTray.items.values

                                    IconImage {
                                        id: trayIcon
                                        required property var modelData
                                        // Some apps (LocalSend) give a file path as the icon name, which the icon theme lookup can't find
                                        source: {
                                            const m = modelData.icon.match(/^image:\/\/icon\/(\/[^?]*)/);
                                            return m ? `file://${m[1]}` : modelData.icon;
                                        }
                                        implicitSize: 18
                                        opacity: trayArea.containsMouse ? 0.7 : 1

                                        MouseArea {
                                            id: trayArea
                                            anchors { fill: parent; margins: -5 }
                                            hoverEnabled: true
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                            // Menus show in the card; a separate popup menu can't open from here
                                            onClicked: mouse => {
                                                const item = trayIcon.modelData;
                                                if (mouse.button !== Qt.MiddleButton && (mouse.button === Qt.RightButton || item.onlyMenu)) {
                                                    if (!item.hasMenu) return;
                                                    bar.trayMenuX = trayArea.mapToItem(panelCard.parent, mouse.x, 0).x;
                                                    root.trayMenus = [item.menu];
                                                    return;
                                                }
                                                root.panel = "";
                                                if (mouse.button === Qt.MiddleButton) item.secondaryActivate();
                                                else item.activate();
                                            }
                                            onWheel: wheel => trayIcon.modelData.scroll(wheel.angleDelta.y, false)
                                        }
                                    }
                                }
                            }
                        }
                        IconButton {
                            id: appsButton
                            visible: SystemTray.items.values.length > 0
                            text: bar.panel === "apps" ? root.nf.right : root.nf.left
                            font.pixelSize: 10 // small, like the Material chevron
                            closesPanel: false
                            onClicked: bar.toggle("apps")
                        }

                        // Media: [ player · position ]; click for the player
                        Label {
                            visible: !!root.player && root.player.playbackState !== MprisPlaybackState.Stopped
                            Layout.leftMargin: 4
                            text: `[ ${(root.player?.identity || "media").split(" ")[0].toLowerCase()} · ${root.formatTime(root.player?.position ?? 0)} ]`
                            opacity: mediaArea.containsMouse ? 0.6 : 1
                            MouseArea {
                                id: mediaArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.mediaOpen = !root.mediaOpen
                            }
                        }

                        // Date and time
                        Label {
                            text: Qt.formatDateTime(clock.date, "ddd MMM d  h:mm AP")
                            color: "#e6ffffff"
                        }

                        IconButton {
                            text: root.ethernet && root.wifiName === "" ? root.nf.ethernet : root.wifiIcon
                            closesPanel: false
                            onClicked: bar.toggle("network")
                        }

                        // Volume, icon and percentage: click for the audio panel, scroll to change volume
                        Item {
                            implicitWidth: volRow.implicitWidth
                            implicitHeight: volRow.implicitHeight
                            opacity: volArea.containsMouse ? 0.6 : 1
                            Row {
                                id: volRow
                                spacing: 6
                                // Fixed width: the speaker glyphs widen with the level and would nudge the row
                                Icon { text: root.volumeIcon; width: 18; horizontalAlignment: Text.AlignHCenter; anchors.verticalCenter: parent.verticalCenter }
                                Label { text: root.muted ? "mute" : `${Math.round(root.volume * 100)}%`; anchors.verticalCenter: parent.verticalCenter }
                            }
                            MouseArea {
                                id: volArea
                                anchors.fill: parent
                                anchors.margins: -5
                                hoverEnabled: true
                                onClicked: bar.toggle("audio")
                                onWheel: wheel => {
                                    if (!root.sink?.audio) return;
                                    root.sink.audio.volume = Math.max(0, Math.min(1, root.volume + (wheel.angleDelta.y > 0 ? 0.02 : -0.02)));
                                }
                            }
                        }
                        // Control center; closes from any of its panels
                        IconButton {
                            text: root.nf.sliders
                            font.pixelSize: 14
                            closesPanel: false
                            onClicked: ["control", "airdrop", "bluetooth", "system"].includes(bar.panel) ? root.panel = "" : bar.toggle("control")
                        }
                        // Session: lock, suspend, log out, restart, shut down
                        IconButton {
                            text: root.nf.power
                            font.pixelSize: 14
                            closesPanel: false
                            onClicked: bar.toggle("user")
                        }
                    }
                }


            }

            // Dropdown panels: a card below the pills, in the top right corner (top left for the user menu)
            Rectangle {
                id: panelCard
                // The tray apps open in the tray pill; the card only shows for one of their menus
                readonly property bool open: bar.panel !== "" && (bar.panel !== "apps" || root.trayMenus.length > 0)
                // The panel whose content is shown; kept while the card closes so it can fade out
                property string shownPanel: ""
                Connections {
                    target: bar
                    function onPanelChanged() { if (panelCard.open) panelCard.shownPanel = bar.panel; }
                }
                onOpenChanged: if (open) shownPanel = bar.panel

                visible: !bar.fullscreen && opacity > 0
                // From the click for a tray menu (kept on screen), otherwise the top right corner
                x: shownPanel === "apps" ? Math.min(bar.trayMenuX, parent.width - width - 12) : parent.width - width - 12
                y: root.barH + 10
                // A tray app's menu is only as wide as its rows
                width: shownPanel === "apps" ? Math.min(parent.width - 24, cardBody.implicitWidth + 24) : shownPanel === "system" ? 400 : 380
                height: open ? cardBody.implicitHeight + 34 : 34
                color: root.glass
                border.width: 1
                border.color: root.edge
                opacity: open ? 1 : 0

                Behavior on height { Motion {} }
                Behavior on opacity { NumberAnimation { duration: 200 } }

                // Frame: noise, corner brackets and tags on the borders
                Grain {}
                Corners {}
                Tag {
                    x: 12
                    y: -height / 2
                    text: ({ user: "SESSION", apps: "MENU", network: "NETWORK", audio: "AUDIO", control: "CONTROL",
                        airdrop: "AIRDROP", bluetooth: "BLUETOOTH", system: "SYSTEM" })[panelCard.shownPanel] ?? ""
                }
                Tag { x: parent.width - width - 12; y: -height / 2; text: "MONOCHROME" }
                Tag { x: 12; y: parent.height - height / 2; text: `GRAIN ${root.boxGrain.toFixed(2)}` }
                Tag { x: parent.width - width - 12; y: parent.height - height / 2; text: `${Math.round(parent.width)} × AUTO` }

                // Clip here, not on the card: its shadow layer pads the area and would show content outside it mid-morph
                Item {
                    anchors.fill: parent
                    clip: true

                    // Swallow clicks on empty card space so they don't reach the close area underneath
                    MouseArea { anchors.fill: parent }

                    ColumnLayout {
                        id: cardBody
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; topMargin: 18 }
                        spacing: 2

                    // App tray menu
                    QsMenuOpener {
                        id: trayMenu
                        menu: root.trayMenus[root.trayMenus.length - 1] ?? null
                    }
                    MenuItem {
                        // Submenus only; the app's own menu closes back to the icons in the tray pill
                        visible: panelCard.shownPanel === "apps" && root.trayMenus.length > 1
                        icon: root.nf.left
                        label: "Back"
                        onClicked: root.trayMenus = root.trayMenus.slice(0, -1)
                    }
                    Repeater {
                        model: panelCard.shownPanel === "apps" && root.trayMenus.length > 0 ? trayMenu.children.values : []

                        Item {
                            id: menuEntry
                            required property var modelData
                            Layout.fillWidth: true
                            implicitWidth: entryRow.implicitWidth + 20
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
                                color: entryArea.containsMouse && menuEntry.modelData.enabled ? "#22ffffff" : "transparent"
                                opacity: menuEntry.modelData.enabled ? 1 : 0.4

                                RowLayout {
                                    id: entryRow
                                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                    spacing: 10
                                    Icon {
                                        visible: menuEntry.modelData.buttonType !== QsMenuButtonType.None
                                        text: menuEntry.modelData.buttonType === QsMenuButtonType.RadioButton
                                            ? (menuEntry.modelData.checkState === Qt.Checked ? root.nf.radioOn : root.nf.radioOff)
                                            : (menuEntry.modelData.checkState === Qt.Checked ? root.nf.checkBox : root.nf.box)
                                    }
                                    Label {
                                        text: menuEntry.modelData.text.replace(/_(?!_)/g, "") // drop mnemonic underscores
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Icon { visible: menuEntry.modelData.hasChildren; text: root.nf.right }
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

                    // Wi-Fi: on/off switch, Ethernet status, then networks; click one to connect (secured new ones ask for a password)
                    RowLayout {
                        visible: panelCard.shownPanel === "network"
                        Layout.margins: 6
                        spacing: 10
                        Icon { text: root.wifiOn ? root.nf.wifi : root.nf.wifiOff }
                        Header { text: "WI-FI"; Layout.fillWidth: true }
                        Toggle {
                            checked: root.wifiOn
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    root.run(`nmcli radio wifi ${root.wifiOn ? "off" : "on"}`);
                                    root.wifiOn = !root.wifiOn; // the 2 s status poll confirms it
                                }
                            }
                        }
                    }
                    RowLayout {
                        visible: panelCard.shownPanel === "network" && root.ethernet
                        Layout.margins: 6
                        spacing: 10
                        Icon { text: root.nf.ethernet }
                        Label { text: "Ethernet connected" }
                    }
                    RowLayout {
                        visible: root.wifiScan && panelCard.shownPanel === "network"
                        Layout.margins: 6
                        Layout.topMargin: 8
                        Header { text: "NETWORKS"; color: root.dim; Layout.fillWidth: true }
                        Label { text: wifiList.running ? "Searching…" : ""; color: "#99ffffff" }
                    }
                    // Scrolls past 320px: the bar surface is 640px tall
                    Flickable {
                        visible: root.wifiScan && panelCard.shownPanel === "network"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentHeight, 320)
                        contentHeight: wifiColumn.implicitHeight
                        clip: true

                        ColumnLayout {
                            id: wifiColumn
                            width: parent.width
                            spacing: 2
                            Repeater {
                                model: root.wifiScan ? root.wifiNetworks : []

                                ColumnLayout {
                                    id: net
                                    required property var modelData
                                    readonly property bool prompt: root.wifiPrompt === modelData.ssid
                                    Layout.fillWidth: true
                                    spacing: 2

                                    MenuItem {
                                        icon: root.nf.wifi
                                        label: net.modelData.ssid
                                            + (root.wifiConnecting === net.modelData.ssid ? "  ·  Connecting…" : net.modelData.active ? "  ·  Connected" : "")
                                        opacity: net.modelData.active ? 1 : 0.6 + 0.4 * net.modelData.signal / 100
                                        onClicked: {
                                            if (net.modelData.active) return;
                                            if (net.modelData.secure && !net.modelData.known) root.wifiPrompt = net.prompt ? "" : net.modelData.ssid;
                                            else root.wifiJoin(net.modelData);
                                        }
                                        Icon {
                                            visible: net.modelData.secure
                                            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                            text: root.nf.lock
                                            font.pixelSize: 12
                                            color: "#99ffffff"
                                        }
                                    }
                                    Rectangle {
                                        visible: net.prompt
                                        Layout.fillWidth: true
                                        Layout.leftMargin: 6
                                        Layout.rightMargin: 6
                                        implicitHeight: 30
                                        color: "transparent"
                                        border.width: 1
                                        border.color: wifiPassword.activeFocus ? "#8a8a8a" : root.edge

                                        TextInput {
                                            id: wifiPassword
                                            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: "white"
                                            font { family: root.mono; pixelSize: 13 }
                                            echoMode: TextInput.Password
                                            passwordCharacter: "*"
                                            cursorDelegate: Rectangle { width: 7; color: "white"; visible: wifiPassword.cursorVisible }
                                            enabled: root.wifiConnecting === ""
                                            clip: true
                                            onVisibleChanged: { text = ""; if (visible) forceActiveFocus(); }
                                            Label {
                                                x: 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: wifiPassword.text === ""
                                                text: "password"
                                                color: "#66ffffff"
                                            }
                                            Keys.onReturnPressed: if (text !== "") root.wifiJoin(net.modelData, text)
                                            Keys.onEnterPressed: if (text !== "") root.wifiJoin(net.modelData, text)
                                            Keys.onEscapePressed: root.wifiPrompt = ""
                                        }
                                    }
                                    Label {
                                        visible: net.prompt && root.wifiError !== ""
                                        text: root.wifiError
                                        color: "#ff8a80"
                                        font.pixelSize: 11
                                        Layout.leftMargin: 10
                                    }
                                }
                            }
                        }
                    }

                    // Audio: volume slider (icon mutes), then outputs; click one to make it the default
                    RowLayout {
                        visible: panelCard.shownPanel === "audio"
                        Layout.margins: 6
                        Layout.leftMargin: 10
                        spacing: 10
                        IconButton {
                            text: root.volumeIcon
                            Layout.preferredWidth: 22
                            closesPanel: false
                            onClicked: if (root.sink?.audio) root.sink.audio.muted = !root.muted
                        }
                        Ticks {
                            Layout.fillWidth: true
                            level: root.volume
                            muted: root.muted
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
                            text: `[ VOL ${String(Math.round(root.volume * 100)).padStart(3)}% ]`
                            color: root.muted ? "#99ffffff" : "white"
                        }
                    }
                    Rectangle {
                        visible: panelCard.shownPanel === "audio"
                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        Layout.rightMargin: 10
                        implicitHeight: 1
                        color: "#26ffffff"
                    }
                    Repeater {
                        model: panelCard.shownPanel === "audio" ? root.sinks : []
                        MenuItem {
                            required property var modelData
                            readonly property bool current: modelData === root.sink
                            icon: current ? root.nf.check : ""
                            // The monitor's name for HDMI/DP audio; when two outputs share it, add the card (first word of the description)
                            readonly property string nick: modelData.nickname || modelData.description || modelData.name
                            label: nick + (root.sinks.filter(n => (n.nickname || n.description || n.name) === nick).length > 1 ? `  ·  ${modelData.description.split(" ")[0]}` : "")
                            onClicked: Pipewire.preferredDefaultAudioSink = modelData
                        }
                    }

                    // User menu: who's logged in, uptime, then power options
                    RowLayout {
                        visible: panelCard.shownPanel === "user"
                        Layout.margins: 6
                        spacing: 10
                        Icon { text: root.nf.user; font.pixelSize: 30 }
                        ColumnLayout {
                            spacing: 0
                            Layout.fillWidth: true
                            Label { text: root.userName; font.bold: true }
                            Label { text: [root.hostName, `Up ${root.uptimeText}`].filter(t => t !== "").join("  ·  "); color: "#99ffffff"; font.pixelSize: 11 }
                        }
                    }
                    Rectangle {
                        visible: panelCard.shownPanel === "user"
                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        Layout.rightMargin: 10
                        Layout.topMargin: 2
                        Layout.bottomMargin: 2
                        implicitHeight: 1
                        color: "#26ffffff"
                    }
                    MenuItem {
                        visible: panelCard.shownPanel === "user"; icon: root.nf.lock; label: "Lock"
                        onClicked: { root.panel = ""; root.locked = true; }
                    }
                    MenuItem {
                        visible: panelCard.shownPanel === "user"; icon: root.nf.moon; label: "Suspend"
                        onClicked: { root.panel = ""; root.run("systemctl suspend"); }
                    }
                    MenuItem {
                        visible: panelCard.shownPanel === "user"; icon: root.nf.logout; label: "Log out"
                        onClicked: Hyprland.dispatch("hl.dsp.exit()")
                    }
                    MenuItem {
                        visible: panelCard.shownPanel === "user"; icon: root.nf.restart; label: "Restart"
                        onClicked: root.run("systemctl reboot")
                    }
                    MenuItem {
                        visible: panelCard.shownPanel === "user"; icon: root.nf.power; label: "Shut down"
                        onClicked: root.run("systemctl poweroff")
                    }

                    // System: CPU, memory, GPU meters, then storage, network and temperatures (sampled only while open)
                    SystemView {
                        visible: panelCard.shownPanel === "system"
                        active: visible
                        Layout.fillWidth: true
                        Layout.margins: 6
                    }

                    // Control center, laid out like the reference: header, switch tiles, display and sound sliders,
                    // today, media, notifications
                    RowLayout {
                        visible: panelCard.shownPanel === "control"
                        Layout.fillWidth: true
                        Layout.leftMargin: 4
                        Layout.bottomMargin: 8
                        Label { text: "Control Center"; Layout.fillWidth: true; font { pixelSize: 15; bold: true } }
                        Label { text: Qt.formatDateTime(clock.date, "ddd d MMM · h:mm AP"); color: root.dim; font.pixelSize: 10 }
                    }
                    GridLayout {
                        visible: panelCard.shownPanel === "control"
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 4
                        rowSpacing: 4

                        CcTile {
                            Layout.row: 0; Layout.column: 0
                            Layout.preferredWidth: 1
                            icon: root.ethernet && root.wifiName === "" ? root.nf.ethernet : root.wifiIcon
                            label: "WI-FI"
                            sub: !root.wifiOn ? "Off" : root.wifiName || (root.ethernet ? "Ethernet" : "...")
                            checked: root.wifiOn
                            onToggled: { root.run(`nmcli radio wifi ${root.wifiOn ? "off" : "on"}`); root.wifiOn = !root.wifiOn; }
                            onClicked: root.panel = "network"
                        }
                        CcTile {
                            Layout.row: 0; Layout.column: 1; Layout.rowSpan: 2
                            Layout.preferredWidth: 1
                            Layout.fillHeight: true
                            stacked: true
                            icon: root.nf.bellOff
                            label: "DO NOT DISTURB"
                            sub: root.dnd ? "On" : "Off"
                            checked: root.dnd
                            onToggled: root.dnd = !root.dnd
                            onClicked: root.dnd = !root.dnd
                        }
                        CcTile {
                            Layout.row: 1; Layout.column: 0
                            Layout.preferredWidth: 1
                            icon: root.nf.bluetooth
                            label: "BLUETOOTH"
                            sub: !(root.btAdapter?.enabled ?? false) ? "Off" : root.btConnected ? `${root.btDevices.filter(d => d.connected).length} connected` : "On"
                            checked: root.btAdapter?.enabled ?? false
                            hasToggle: root.btAdapter !== null
                            onToggled: root.btAdapter.enabled = !root.btAdapter.enabled
                            onClicked: if (root.btAdapter) root.panel = "bluetooth"
                        }
                        CcTile {
                            Layout.row: 2; Layout.column: 0; Layout.columnSpan: 2
                            stacked: true
                            icon: root.nf.nightLight
                            label: "NIGHT LIGHT"
                            sub: root.nightLight ? "On · 4000 K" : "Off"
                            checked: root.nightLight
                            onToggled: root.nightLight = !root.nightLight
                            onClicked: root.nightLight = !root.nightLight
                        }
                        // Switch: system monitor on the desktop; the tile opens the system panel
                        CcTile {
                            Layout.row: 3; Layout.column: 0; Layout.columnSpan: 2
                            stacked: true
                            icon: root.nf.memory
                            label: "SYSTEM"
                            sub: `CPU ${Math.round(root.cpu * 100)}% · RAM ${Math.round(root.mem.used / root.mem.total * 100)}%`
                            checked: root.showSysWidget
                            onToggled: root.showSysWidget = !root.showSysWidget
                            onClicked: root.panel = "system"
                        }
                        CcTile {
                            Layout.row: 4; Layout.column: 0
                            Layout.preferredWidth: 1
                            iconSource: "icons/airdrop.svg"
                            label: "AIRDROP"
                            sub: airdrop.stateText
                            checked: airdrop.busy ? airdrop.turningOn : airdrop.receiving
                            hasToggle: airdrop.usable
                            onToggled: airdrop.toggle()
                            onClicked: root.panel = "airdrop"
                        }
                        CcTile {
                            Layout.row: 4; Layout.column: 1
                            Layout.preferredWidth: 1
                            // Custom SVGs: no cup in the icon font's style
                            iconSource: root.keepAwake ? "icons/cup_fill.svg" : "icons/cup.svg"
                            label: "KEEP AWAKE"
                            sub: root.keepAwake ? "On" : "Off"
                            checked: root.keepAwake
                            onToggled: root.keepAwake = !root.keepAwake
                            onClicked: root.keepAwake = !root.keepAwake
                        }
                    }

                    // Display and sound: sparse tick sliders with a handle
                    ColumnLayout {
                        visible: panelCard.shownPanel === "control"
                        Layout.fillWidth: true
                        Layout.topMargin: 12
                        Layout.leftMargin: 4
                        spacing: 6

                        Label { text: "DISPLAY"; color: root.dim; font { pixelSize: 10; letterSpacing: 1 } }
                        RowLayout {
                            spacing: 10
                            Ticks {
                                Layout.fillWidth: true
                                implicitHeight: 14
                                pitch: 10
                                handle: true
                                level: Math.max(0, root.brightness) / 100
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    function set(x) { root.setBrightness((x - 6) / (width - 12) * 100); }
                                    onPressed: mouse => set(mouse.x)
                                    onPositionChanged: mouse => set(mouse.x)
                                    onWheel: wheel => root.setBrightness(root.brightness + (wheel.angleDelta.y > 0 ? 5 : -5))
                                }
                            }
                            Label { text: `[ BRT ${root.brightness < 0 ? "--" : root.brightness}% ]`; color: root.dim; font.pixelSize: 10 }
                            Icon { text: root.brightness < 50 ? root.nf.sunLow : root.nf.sunHigh; font.pixelSize: 14 }
                        }

                        Label { text: "SOUND"; color: root.dim; Layout.topMargin: 6; font { pixelSize: 10; letterSpacing: 1 } }
                        RowLayout {
                            spacing: 10
                            Ticks {
                                Layout.fillWidth: true
                                implicitHeight: 14
                                pitch: 10
                                handle: true
                                level: root.volume
                                muted: root.muted
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    function set(x) { if (root.sink?.audio) root.sink.audio.volume = Math.max(0, Math.min(1, (x - 6) / (width - 12))); }
                                    onPressed: mouse => set(mouse.x)
                                    onPositionChanged: mouse => set(mouse.x)
                                    onWheel: wheel => { if (root.sink?.audio) root.sink.audio.volume = Math.max(0, Math.min(1, root.volume + (wheel.angleDelta.y > 0 ? 0.02 : -0.02))); }
                                }
                            }
                            Label { text: `[ VOL ${Math.round(root.volume * 100)}% ]`; color: root.dim; font.pixelSize: 10 }
                            IconButton {
                                text: root.volumeIcon
                                font.pixelSize: 14
                                closesPanel: false
                                onClicked: if (root.sink?.audio) root.sink.audio.muted = !root.muted
                            }
                        }
                    }

                    // Today, and the next marked days from the desktop calendar
                    Rectangle { visible: panelCard.shownPanel === "control"; Layout.fillWidth: true; Layout.topMargin: 12; implicitHeight: 1; color: "#26ffffff" }
                    RowLayout {
                        visible: panelCard.shownPanel === "control"
                        Layout.fillWidth: true
                        Layout.topMargin: 10
                        Layout.leftMargin: 4
                        spacing: 8
                        Icon { text: root.nf.calendar; font.pixelSize: 13 }
                        Label { text: Qt.formatDate(clock.date, "dddd d MMMM"); Layout.fillWidth: true; font { pixelSize: 13; bold: true } }
                        Label { text: Qt.formatDate(clock.date, "yyyy"); color: root.dim; font.pixelSize: 10 }
                    }
                    Label {
                        readonly property var upcoming: root.marks.filter(m => m >= root.dayKey(clock.date)).slice(0, 3)
                        visible: panelCard.shownPanel === "control"
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        Layout.bottomMargin: 6
                        horizontalAlignment: Text.AlignHCenter
                        text: upcoming.length === 0 ? "No upcoming events"
                            : "Marked: " + upcoming.map(m => Qt.formatDate(new Date(`${m}T00:00`), "ddd d MMM")).join(" · ")
                        color: root.dim
                        font.pixelSize: 11
                    }

                    // Media: art, title, artist, player; then controls
                    Rectangle { visible: panelCard.shownPanel === "control" && !!root.player; Layout.fillWidth: true; Layout.topMargin: 6; implicitHeight: 1; color: "#26ffffff" }
                    RowLayout {
                        visible: panelCard.shownPanel === "control" && !!root.player
                        Layout.fillWidth: true
                        Layout.topMargin: 10
                        Layout.leftMargin: 4
                        spacing: 10
                        ClippingRectangle {
                            implicitWidth: 44
                            implicitHeight: 44
                            color: "#1affffff"
                            Image {
                                id: ccArt
                                anchors.fill: parent
                                source: root.player?.trackArtUrl ?? ""
                                fillMode: Image.PreserveAspectCrop
                                sourceSize: Qt.size(88, 88)
                                asynchronous: true
                            }
                            Icon { anchors.centerIn: parent; visible: ccArt.status !== Image.Ready; text: root.nf.music; color: "#66ffffff" }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Label { Layout.fillWidth: true; text: root.player?.trackTitle || root.player?.identity || ""; font.bold: true; elide: Text.ElideRight }
                            Label { Layout.fillWidth: true; text: root.player?.trackArtist ?? ""; color: root.dim; font.pixelSize: 11; elide: Text.ElideRight }
                            Label { Layout.fillWidth: true; text: (root.player?.identity ?? "").toLowerCase(); color: "#59ffffff"; font.pixelSize: 9 }
                        }
                    }
                    RowLayout {
                        visible: panelCard.shownPanel === "control" && !!root.player
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 6
                        Layout.bottomMargin: 4
                        spacing: 26
                        IconButton { text: root.nf.prev; font.pixelSize: 14; closesPanel: false; enabled: root.player?.canGoPrevious ?? false; opacity: enabled ? 1 : 0.4; onClicked: root.player.previous() }
                        IconButton { text: root.player?.isPlaying ? root.nf.pause : root.nf.play; font.pixelSize: 18; closesPanel: false; onClicked: root.player.togglePlaying() }
                        IconButton { text: root.nf.next; font.pixelSize: 14; closesPanel: false; enabled: root.player?.canGoNext ?? false; opacity: enabled ? 1 : 0.4; onClicked: root.player.next() }
                    }

                    Rectangle { visible: panelCard.shownPanel === "control"; Layout.fillWidth: true; Layout.topMargin: 6; implicitHeight: 1; color: "#26ffffff" }
                    Label {
                        visible: panelCard.shownPanel === "control" && notifications.trackedNotifications.values.length === 0
                        Layout.fillWidth: true
                        Layout.topMargin: 18
                        Layout.bottomMargin: 14
                        horizontalAlignment: Text.AlignHCenter
                        text: "No notifications"
                        color: "#59ffffff"
                    }
                    // Notifications, newest first; Clear all dismisses them
                    RowLayout {
                        visible: panelCard.shownPanel === "control" && notifications.trackedNotifications.values.length > 0
                        Layout.margins: 6
                        Header { text: "NOTIFICATIONS"; Layout.fillWidth: true }
                        Label {
                            text: "[ clear all ]"
                            color: "#99ffffff"
                            MouseArea {
                                anchors.fill: parent
                                onClicked: [...notifications.trackedNotifications.values].forEach(n => n.dismiss())
                            }
                        }
                    }
                    // Scrolls past 220px, so the control center fits the bar surface
                    Flickable {
                        visible: panelCard.shownPanel === "control"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentHeight, 220)
                        contentHeight: notifList.implicitHeight
                        clip: true

                        ColumnLayout {
                            id: notifList
                            width: parent.width
                            spacing: 4
                            Repeater {
                                model: panelCard.shownPanel === "control" ? [...notifications.trackedNotifications.values].reverse() : []

                                Rectangle {
                                    id: entry
                                    required property var modelData
                                    Layout.fillWidth: true
                                    implicitHeight: entryBody.implicitHeight + 16
                                    color: "transparent"
                                    border.width: 1
                                    border.color: "#2e2e2e"

                                    ColumnLayout {
                                        id: entryBody
                                        anchors { left: parent.left; right: dismiss.left; verticalCenter: parent.verticalCenter; leftMargin: 12 }
                                        spacing: 1
                                        Label { text: entry.modelData.appName.toUpperCase(); color: root.dim; font { pixelSize: 10; letterSpacing: 1 } }
                                        Label { text: entry.modelData.summary; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
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
                                        text: root.nf.close
                                        font.pixelSize: 15
                                        closesPanel: false
                                        onClicked: entry.modelData.dismiss()
                                    }
                                }
                            }
                        }
                    }

                    // Panels opened from the control center lead back to it
                    MenuItem {
                        visible: ["airdrop", "bluetooth"].includes(panelCard.shownPanel)
                        icon: root.nf.left
                        label: "Control Center"
                        onClicked: root.panel = "control"
                    }

                    // AirDrop: on/off, how long to stay visible, who may send, nearby devices to send to, save folder
                    Rectangle {
                        visible: panelCard.shownPanel === "airdrop"
                        Layout.fillWidth: true
                        implicitHeight: 44
                        color: airdropArea.containsMouse && airdrop.usable ? "#22ffffff" : "transparent"

                        RowLayout {
                            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                            spacing: 10
                            Image { source: "icons/airdrop.svg"; sourceSize: Qt.size(17, 17); Layout.preferredWidth: 20; fillMode: Image.Pad; opacity: airdrop.receiving ? 1 : 0.6 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Label { text: "AirDrop"; font.bold: true; Layout.fillWidth: true }
                                Label { text: airdrop.stateText; color: "#99ffffff"; font.pixelSize: 11; Layout.fillWidth: true }
                            }
                            // Switch; shows where it's going while busy
                            Toggle {
                                visible: airdrop.usable
                                checked: airdrop.busy ? airdrop.turningOn : airdrop.receiving
                                opacity: airdrop.busy ? 0.6 : 1
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
                        visible: panelCard.shownPanel === "airdrop" && airdrop.detailText !== ""
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
                        visible: panelCard.shownPanel === "airdrop" && airdrop.usable
                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        Layout.rightMargin: 10
                        implicitHeight: 1
                        color: "#26ffffff"
                    }
                    // Stay visible for: discrete stops; releasing during a window restarts it at the new length
                    RowLayout {
                        visible: panelCard.shownPanel === "airdrop" && airdrop.usable
                        Layout.margins: 6
                        Layout.leftMargin: 10
                        Layout.rightMargin: 10
                        spacing: 10
                        Icon { text: root.nf.timer; Layout.preferredWidth: 22; horizontalAlignment: Text.AlignHCenter }
                        Item {
                            Layout.fillWidth: true
                            implicitHeight: 20
                            readonly property int last: airdrop.windowStops.length - 1
                            Ticks {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                level: (airdrop.windowIndex + 1) / (parent.last + 1)
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
                        visible: panelCard.shownPanel === "airdrop" && airdrop.usable
                        icon: airdrop.audience === "everyone" ? root.nf.check : ""
                        label: "Everyone"
                        onClicked: airdrop.setAudience("everyone")
                    }
                    MenuItem {
                        visible: panelCard.shownPanel === "airdrop" && airdrop.usable
                        icon: airdrop.audience === "contacts" ? root.nf.check : ""
                        label: `Contacts only  ·  ${airdrop.senders} known ${airdrop.senders === 1 ? "sender" : "senders"}`
                        onClicked: airdrop.setAudience("contacts")
                    }
                    Rectangle {
                        visible: panelCard.shownPanel === "airdrop" && airdrop.usable
                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        Layout.rightMargin: 10
                        implicitHeight: 1
                        color: "#26ffffff"
                    }
                    Label {
                        visible: panelCard.shownPanel === "airdrop" && airdrop.usable
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
                        model: panelCard.shownPanel === "airdrop" && airdrop.usable ? airdrop.peers : []
                        MenuItem {
                            required property var modelData
                            readonly property bool target: airdrop.sendingTo === modelData.mac
                            icon: target && airdrop.sendFailed ? root.nf.alert : root.nf.send
                            label: modelData.name + (target && airdrop.sendStatus !== "" ? `  ·  ${airdrop.sendStatus}` : "")
                            opacity: airdrop.sending && !target ? 0.5 : 1
                            onClicked: target ? (airdrop.sending ? airdrop.cancelSend() : airdrop.dismissSend()) : airdrop.send(modelData.mac)
                        }
                    }
                    MenuItem {
                        visible: panelCard.shownPanel === "airdrop" && airdrop.usable
                        icon: root.nf.folder
                        label: `Save to ${airdrop.dir.replace(Quickshell.env("HOME"), "~") || "…"}`
                        onClicked: airdrop.pickDir()
                    }

                    // Bluetooth: on/off, paired devices (click to connect or disconnect), then nearby devices found by
                    // scanning while the panel is open (click to pair and connect)
                    MenuItem {
                        visible: panelCard.shownPanel === "bluetooth" && root.btAdapter !== null
                        icon: ""
                        iconSource: "icons/bluetooth.svg"
                        label: root.btAdapter?.enabled ? "Turn Bluetooth off" : "Turn Bluetooth on"
                        onClicked: root.btAdapter.enabled = !root.btAdapter.enabled
                    }
                    Repeater {
                        model: panelCard.shownPanel === "bluetooth" && (root.btAdapter?.enabled ?? false) ? root.btDevices : []
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
                    RowLayout {
                        visible: panelCard.shownPanel === "bluetooth" && (root.btAdapter?.enabled ?? false)
                        Layout.margins: 6
                        Layout.topMargin: 8
                        Header { text: "NEARBY"; color: root.dim; Layout.fillWidth: true }
                        Label { text: root.btAdapter?.discovering ? "Searching…" : ""; color: "#99ffffff" }
                    }
                    Repeater {
                        model: panelCard.shownPanel === "bluetooth" && (root.btAdapter?.enabled ?? false) ? root.btNearby : []
                        MenuItem {
                            required property var modelData
                            icon: root.btIcon(modelData)
                            iconSource: icon === "" ? "icons/bluetooth.svg" : ""
                            label: modelData.name + (modelData.pairing ? "  ·  Pairing…" : "")
                            opacity: 0.6
                            onClicked: root.btPair(modelData)
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
