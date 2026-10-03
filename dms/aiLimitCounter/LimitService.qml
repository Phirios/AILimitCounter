pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "format.js" as Format

// Refresh schedule and per-provider state. DMS creates one widget per bar, so this lives in a
// singleton: two monitors still mean one poll, and every bar shows the same numbers.
Singleton {
    id: root

    readonly property var providers: [
        {id: "claude", label: "Claude", title: "Claude Code"},
        {id: "codex", label: "GPT", title: "Codex (ChatGPT)"}
    ]
    readonly property int tickSecs: 60
    readonly property var emptyEntry: ({usage: null, error: null, live: false, fetchedAt: 0})

    // Set by the widgets from the plugin settings.
    property string provider: "claude"
    property string helperPath: ""
    /** Widgets currently on screen; polling stops when the plugin is disabled. */
    property int consumers: 0

    property var entries: ({claude: emptyEntry, codex: emptyEntry})
    property int now: nowSecs()
    property int lastTickAt: 0

    readonly property var entry: entries[provider]
    readonly property bool loading: processFor(provider).busy

    function nowSecs() {
        return Math.floor(Date.now() / 1000);
    }

    function attach(selectedProvider, path) {
        provider = selectedProvider;
        helperPath = path;
        consumers += 1;
        // DMS recreates bar widgets now and then; only a stale schedule needs a tick right away.
        if (nowSecs() - lastTickAt >= tickSecs)
            tick();
    }

    function detach() {
        consumers = Math.max(0, consumers - 1);
    }

    function processFor(id) {
        return id === "claude" ? claudeProcess : codexProcess;
    }

    function updateEntry(id, changes) {
        const next = Object.assign({}, entries);
        next[id] = Object.assign({}, entries[id], changes);
        entries = next;
    }

    function refresh(id, force) {
        if (consumers === 0 || helperPath === "")
            return;
        if (!Format.mayRefresh(id, entries[id].fetchedAt, nowSecs(), force))
            return;
        processFor(id).start();
    }

    function refreshAll() {
        now = nowSecs();
        for (const item of providers)
            refresh(item.id, false);
    }

    function applyReport(id, text) {
        const report = Format.parseUsage(text);
        const changes = {error: report.error, fetchedAt: nowSecs()};
        // Codex must not retain numbers from a previously signed-in account.
        if (id === "codex")
            changes.usage = report.usage;
        // Keep the last good Claude numbers on screen when a refresh fails.
        if (report.usage)
            changes.usage = report.usage;
        updateEntry(id, changes);
    }

    function reportMissingHelper(id) {
        updateEntry(id, {
            error: "Helper not found at " + helperPath + " — run dms/install.sh",
            fetchedAt: nowSecs()
        });
    }

    function applyLiveness(text) {
        const running = text.split("\n");
        for (const item of providers)
            updateEntry(item.id, {live: running.indexOf(item.id) !== -1});
    }

    function tick() {
        if (consumers === 0)
            return;
        now = nowSecs();
        lastTickAt = now;
        if (!livenessProcess.running)
            livenessProcess.running = true;

        // Read the default Codex account quota once per minute.
        refresh("codex", false);
        if (provider === "claude" && Format.isClaudeDue(entries.claude.fetchedAt, now, entries.claude.live))
            refresh("claude", false);
    }

    onProviderChanged: refresh(provider, false)

    // Always running: tying it to the widgets would reset the interval, and fire an extra
    // tick, every time DMS recreates them.
    Timer {
        interval: root.tickSecs * 1000
        repeat: true
        running: true
        onTriggered: root.tick()
    }

    // One helper run. Exit and end-of-output arrive in no fixed order, so a run is only
    // finished once both were seen; `busy` keeps a second run from starting in between.
    component HelperProcess: Process {
        id: helper

        property bool busy: false
        property bool wasStarted: false
        property bool exitSeen: false
        property bool outputSeen: false

        signal reported(string text)
        signal startFailed

        function start() {
            if (busy)
                return;
            busy = true;
            wasStarted = false;
            exitSeen = false;
            outputSeen = false;
            running = true;
        }

        function finishIfDone() {
            if (!busy || !exitSeen || !outputSeen)
                return;
            busy = false;
            reported(stdout.text);
        }

        stdout: StdioCollector {
            onStreamFinished: {
                helper.outputSeen = true;
                helper.finishIfDone();
            }
        }
        onStarted: wasStarted = true
        onExited: {
            exitSeen = true;
            finishIfDone();
        }
        // A binary that cannot be started never exits or reports; it only stops "running".
        onRunningChanged: {
            if (running || !busy || wasStarted)
                return;
            busy = false;
            startFailed();
        }
    }

    HelperProcess {
        id: claudeProcess

        command: [root.helperPath, "--json", "claude"]
        onReported: text => root.applyReport("claude", text)
        onStartFailed: root.reportMissingHelper("claude")
    }

    HelperProcess {
        id: codexProcess

        command: [root.helperPath, "--json", "codex"]
        onReported: text => root.applyReport("codex", text)
        onStartFailed: root.reportMissingHelper("codex")
    }

    // Exact name match, so paths and arguments containing "claude" don't count.
    Process {
        id: livenessProcess

        command: ["sh", "-c", "for name in claude codex; do pgrep -x \"$name\" >/dev/null && echo \"$name\"; done; true"]
        stdout: StdioCollector {
            onStreamFinished: root.applyLiveness(text)
        }
    }
}
