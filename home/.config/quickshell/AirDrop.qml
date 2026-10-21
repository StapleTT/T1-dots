import QtQuick
import Quickshell
import Quickshell.Io

// AirDrop through the omdrop CLI (~/omdrop-plugin). The CLI is the source of truth: this polls
// `omdrop status --json` and runs its commands; the bar's tray pill draws the result.
Scope {
    id: ad

    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omdrop"

    // Set by the bar: the AirDrop dropdown is showing. Polls faster and scans for peers while true.
    property bool panelOpen: false
    // The chooser (send / save folder) needs the dropdown out of the way, and it comes back after
    signal panelWanted(bool open)

    property bool installed: false
    property bool receiving: false
    property int visibility: -1 // -1 unknown (radio side missing), 0 no, 1 yes
    property int remaining: -1
    property string mode: "off"
    property string deviceName: ""
    property string dir: ""
    property string audience: "everyone"
    property int senders: 0
    property string reason: ""
    property string lastError: ""
    property string doctorText: ""
    property bool busy: false
    property bool turningOn: false

    readonly property bool usable: installed && visibility !== -1

    // The radio takes ~10s after the receiver starts; count it rather than calling it a fault
    property int settleElapsed: 0
    readonly property bool settling: receiving && visibility !== 1 && settleElapsed < 200
    Timer {
        interval: 1000; repeat: true
        running: ad.receiving && ad.visibility !== 1
        onTriggered: ad.settleElapsed++
        onRunningChanged: if (!running) ad.settleElapsed = 0
    }

    readonly property var windowStops: [
        { arg: "once", label: "One file" },
        { arg: "1m", label: "1 min" },
        { arg: "5m", label: "5 min" },
        { arg: "10m", label: "10 min" },
        { arg: "15m", label: "15 min" },
        { arg: "30m", label: "30 min" },
        { arg: "60m", label: "1 hour" },
        { arg: "forever", label: "Always" }
    ]
    property int windowIndex: 3
    property bool windowPicking: false
    readonly property string windowArg: windowStops[windowIndex].arg

    function clock(s) {
        const m = Math.floor(s / 60), sec = s % 60;
        return `${m}:${sec < 10 ? "0" : ""}${sec}`;
    }
    readonly property bool countingDown: receiving && remaining > 0
    readonly property string windowText: countingDown && !windowPicking ? `${clock(remaining)} left` : windowStops[windowIndex].label

    readonly property string stateText: {
        if (!usable) return "Not available";
        if (busy) return turningOn ? "Turning on…" : "Turning off…";
        if (settling) return "Waking the radio…";
        if (!receiving) return "Off";
        if (visibility === 0) return "Nobody can see you yet";
        return audience === "contacts" ? "Contacts only" : "Everyone";
    }

    readonly property string detailText: {
        if (!usable) return doctorText || "Needs the AWDL radio backend (omdrop-owl).";
        if (busy) return "";
        if (lastError !== "") return lastError;
        if (settling) return "The radio takes a few seconds to come up.";
        if (reason !== "" && !["ok", "expired", "stopped", "parked"].includes(reason) && visibility !== 1) return `The radio side reports: ${reason}`;
        if (!receiving) return "";
        if (visibility === 0) return "The receiver is up, but nothing is advertising on the radio.";
        if (audience === "contacts" && senders === 0) return "Your known-senders list is empty, so everyone is refused. Add people with: omdrop senders add EMAIL";
        return `Visible as “${deviceName}”`;
    }

    function toggle() {
        if (busy || !usable) return;
        turningOn = !receiving;
        busy = true;
        lastError = "";
        toggleProc.command = [cli, "toggle", windowArg];
        toggleProc.running = true;
    }
    Process {
        id: toggleProc
        stderr: StdioCollector { onStreamFinished: ad.lastError = text.trim() }
        onExited: code => { ad.busy = false; if (code === 0) ad.lastError = ""; ad.refresh(); }
    }

    // Moving the slider during a window restarts it with the new length, counting from now
    function reschedule() {
        if (!receiving || busy || !usable) return;
        mode = windowArg === "once" || windowArg === "forever" ? windowArg : "timed";
        run([cli, "on", windowArg]);
    }

    function setAudience(m) {
        if (m === audience) return;
        audience = m;
        run([cli, "visibility", m]);
    }

    // One-shot commands: show what they say on failure, then re-read the status
    function run(cmd) {
        lastError = "";
        const p = cmdProc.createObject(ad, { command: cmd });
        p.running = true;
    }
    Component {
        id: cmdProc
        Process {
            stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") ad.lastError = text.trim() }
            onExited: { ad.refresh(); destroy(); }
        }
    }

    function pickDir() {
        if (pickDirProc.running) return;
        lastError = "";
        pickDirProc.running = true;
        panelWanted(false);
    }
    Process {
        id: pickDirProc
        command: [ad.cli, "dir", "--pick"]
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") ad.lastError = text.trim() }
        onExited: { ad.panelWanted(true); ad.refresh(); }
    }

    // --- status

    // A refresh asked for mid-poll is queued: that poll's answer predates the change
    property bool stale: false
    function refresh() {
        if (statusProc.running) stale = true;
        else statusProc.running = true;
    }
    Process {
        id: statusProc
        command: [ad.cli, "status", "--json"]
        stdout: StdioCollector { onStreamFinished: if (!ad.stale) ad.apply(text) }
        onExited: code => {
            if (ad.stale) { ad.stale = false; running = true; return; }
            if (code !== 0) ad.installed = false;
        }
    }
    function apply(text) {
        try {
            const s = JSON.parse(text);
            installed = true;
            receiving = !!s.receiving;
            visibility = s.visible === null || s.visible === undefined ? -1 : s.visible ? 1 : 0;
            remaining = s.remaining ?? -1;
            deviceName = s.name || "";
            dir = s.dir || "";
            reason = s.reason || "";
            audience = s.visibility === "contacts" ? "contacts" : "everyone";
            senders = s.senders || 0;
            syncWindow(s.mode || "off");
            if (!usable && doctorText === "" && !doctorProc.running) doctorProc.running = true;
            if (usable) doctorText = "";
        } catch (e) {
            installed = false;
        }
    }
    // While a window runs, the slider shows that window (only on a change, so it never fights a drag)
    function syncWindow(m) {
        if (windowPicking || m === mode) return;
        mode = m;
        if (m === "once") windowIndex = 0;
        else if (m === "forever") windowIndex = windowStops.length - 1;
        else if (m === "timed" && remaining > 0) {
            for (let i = 1; i < windowStops.length - 1; i++)
                if (parseInt(windowStops[i].arg) >= remaining / 60) { windowIndex = i; break; }
        }
    }
    Process {
        id: doctorProc
        command: [ad.cli, "doctor", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { ad.doctorText = (JSON.parse(text).missing || [])[0]?.say || ""; } catch (e) { ad.doctorText = ""; }
            }
        }
    }

    Timer {
        interval: ad.panelOpen ? 3000 : 10000; repeat: true; running: true; triggeredOnStart: true
        onTriggered: if (!statusProc.running) statusProc.running = true
    }
    onPanelOpenChanged: if (panelOpen && !busy) refresh()
    // The countdown ticks locally rather than polling every second
    Timer {
        interval: 1000; repeat: true
        running: ad.countingDown
        onTriggered: {
            ad.remaining--;
            if (ad.remaining <= 0) { ad.remaining = -1; ad.receiving = false; ad.refresh(); }
        }
    }

    // --- nearby devices
    // `peers --json` is passive and quick; `peers -n --stream` connects to each peer for its name
    // (slow), so it runs back to back only while the dropdown is open. Only named peers are listed.

    readonly property bool scanning: panelOpen && receiving && visibility === 1
    property var peerNames: ({}) // mac -> name, kept for the session
    property var heard: []       // macs from the last passive listing
    readonly property var peers: {
        const list = heard.filter(m => peerNames[m]).map(m => ({ mac: m, name: peerNames[m] }));
        if (sendingTo !== "" && !list.some(p => p.mac === sendingTo)) list.push({ mac: sendingTo, name: peerNames[sendingTo] || sendingTo });
        return list;
    }

    Timer {
        interval: 2000; repeat: true; triggeredOnStart: true
        running: ad.scanning
        onTriggered: if (!peersProc.running) peersProc.running = true
    }
    Process {
        id: peersProc
        command: [ad.cli, "peers", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { ad.heard = JSON.parse(text).map(p => p.mac); } catch (e) {}
            }
        }
    }
    Process {
        id: namesProc
        command: [ad.cli, "peers", "--json", "-n", "--stream"]
        property double startedAt: 0
        onStarted: startedAt = Date.now()
        stdout: SplitParser {
            onRead: line => {
                try {
                    const p = JSON.parse(line);
                    if (p.mac && p.name && ad.peerNames[p.mac] !== p.name) ad.peerNames = Object.assign({}, ad.peerNames, { [p.mac]: p.name });
                } catch (e) {}
            }
        }
        // A lookup that fails at once would loop tightly, so a quick exit waits before the next
        onExited: namesAgain.interval = Date.now() - startedAt < 5000 ? 10000 : 250
    }
    Timer {
        id: namesAgain
        interval: 250; repeat: true; triggeredOnStart: true
        running: ad.scanning && !namesProc.running
        onTriggered: if (!namesProc.running) namesProc.running = true
    }
    onScanningChanged: if (!scanning && namesProc.running) namesProc.signal(15)

    // --- sending: one at a time. The CLI opens a file chooser, then narrates the transfer line by line.

    property string sendingTo: ""
    property string sendStatus: ""
    property bool sendChosen: false
    property bool sendCancelled: false
    property bool sendFailed: false
    property string sendingFile: ""
    readonly property bool sending: sendProc.running

    function send(mac) {
        if (sendProc.running) return;
        sendingTo = mac;
        sendStatus = "Choose files…";
        sendChosen = false;
        sendCancelled = false;
        sendFailed = false;
        sendingFile = "";
        sendClear.stop();
        sendProc.command = [cli, "send", "--pick", "--to", mac];
        sendProc.running = true;
        panelWanted(false);
    }
    function cancelSend() {
        if (!sendProc.running) return;
        sendCancelled = true;
        sendStatus = "Cancelling…";
        sendProc.signal(15); // the CLI stops the sender's whole process group
    }
    function dismissSend() {
        if (sendProc.running) return;
        sendingTo = "";
        sendStatus = "";
        sendFailed = false;
    }
    Process {
        id: sendProc
        stdout: SplitParser {
            onRead: line => {
                line = line.trim();
                if (line === "") return;
                if (!ad.sendChosen) { ad.sendChosen = true; ad.panelWanted(true); }
                const chosen = /^Preparing (.*)\.\.\.$/.exec(line);
                if (chosen) ad.sendingFile = chosen[1];
                ad.sendStatus = line;
            }
        }
        stderr: SplitParser {
            onRead: line => {
                line = line.trim();
                if (line === "") return;
                // "sending /path to <mac> at [fe80::…]:8770" / "waiting up to 30s for …" both mean the file is on its way
                const s = /^sending (.*) to \S+ at /.exec(line);
                if (s || /^waiting up to \d+s for .* to start listening/.test(line))
                    line = `Sending ${ad.sendingFile || (s ? s[1].replace(/^.*\//, "") : "the file")}…`;
                ad.sendStatus = line;
            }
        }
        onExited: code => {
            // A cancelled chooser is exit 1 with nothing said
            if (ad.sendCancelled || (code !== 0 && !ad.sendChosen)) {
                if (!ad.sendChosen) ad.panelWanted(true);
                ad.dismissSend();
                return;
            }
            ad.sendFailed = code !== 0;
            if (!ad.sendFailed) sendClear.restart();
        }
    }
    Timer { id: sendClear; interval: 2500; onTriggered: ad.dismissSend() }

    IpcHandler {
        target: "airdrop"
        function toggle(): void { ad.toggle(); }
        function status(): string { return ad.stateText; }
    }
}
