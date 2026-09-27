import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "format.js" as Format

// Bar pill (ring + percentage) and drop-down panel; owns the refresh schedule and per-provider state.
PluginComponent {
    id: root

    readonly property var providers: [
        {id: "claude", label: "Claude", title: "Claude Code"},
        {id: "codex", label: "GPT", title: "Codex (ChatGPT)"}
    ]
    readonly property string provider: pluginData.provider === "codex" ? "codex" : "claude"
    readonly property string helperPath: Format.expandHome(pluginData.helperPath || "~/.local/bin/ai-limit-counter", Quickshell.env("HOME"))

    readonly property int tickSecs: 60
    /** A forced refresh aside, Claude is never asked more often than this. */
    readonly property int claudeMinAgeSecs: 60
    readonly property var emptyEntry: ({usage: null, error: null, live: false, fetchedAt: 0})

    property var entries: ({claude: emptyEntry, codex: emptyEntry})
    property int now: nowSecs()

    readonly property var entry: entries[provider]
    readonly property bool loading: processFor(provider).busy
    // Typed as colors (not strings) so Theme.withAlpha can read their channels.
    readonly property color claudeAccent: "#d97757"
    readonly property color codexAccent: Theme.isLightMode ? "#1b1b1f" : "#f4f4f6"
    readonly property color textOnClaude: "#ffffff"
    readonly property color textOnCodex: Theme.isLightMode ? "#ffffff" : "#111114"
    readonly property color criticalColor: "#f87171"
    readonly property color idleColor: "#9e9ea8"
    readonly property string pillText: entry.usage ? entry.usage.fiveHour.pct + "%" : entry.error ? "!" : "…"

    function nowSecs() {
        return Math.floor(Date.now() / 1000);
    }

    function accentFor(id) {
        return id === "claude" ? claudeAccent : codexAccent;
    }

    function textOnAccent(id) {
        return id === "claude" ? textOnClaude : textOnCodex;
    }

    function windowColor(usageWindow) {
        if (!usageWindow)
            return idleColor;
        return Format.levelFor(usageWindow.pct) === "crit" ? criticalColor : accentFor(provider);
    }

    function processFor(id) {
        return id === "claude" ? claudeProcess : codexProcess;
    }

    function updateEntry(id, changes) {
        const next = Object.assign({}, entries);
        next[id] = Object.assign({}, entries[id], changes);
        entries = next;
    }

    function selectProvider(id) {
        if (id === provider || !pluginService)
            return;
        pluginService.savePluginData(pluginId, "provider", id);
    }

    function refresh(id, force) {
        if (id === "claude" && !force && nowSecs() - entries.claude.fetchedAt < claudeMinAgeSecs)
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
        // Keep the last good numbers on screen when a refresh fails.
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
        now = nowSecs();
        if (!livenessProcess.running)
            livenessProcess.running = true;

        // Codex reads local files only, so it is always cheap to refresh.
        refresh("codex", false);
        if (provider === "claude" && Format.isClaudeDue(entries.claude.fetchedAt, now, entries.claude.live))
            refresh("claude", false);
    }

    onProviderChanged: refresh(provider, false)

    Timer {
        interval: root.tickSecs * 1000
        repeat: true
        running: true
        triggeredOnStart: true
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

    component LiveDot: Rectangle {
        id: dot

        property bool live: false

        width: 6
        height: 6
        radius: 3
        visible: live

        SequentialAnimation on opacity {
            running: dot.live
            loops: Animation.Infinite
            alwaysRunToEnd: false

            NumberAnimation {
                to: 0.28
                duration: 900
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                to: 1
                duration: 900
                easing.type: Easing.InOutSine
            }
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS + 2

            LimitRing {
                anchors.verticalCenter: parent.verticalCenter
                size: Theme.iconSize - 6
                fiveHourPct: root.entry.usage ? root.entry.usage.fiveHour.pct : -1
                sevenDayPct: root.entry.usage ? root.entry.usage.sevenDay.pct : -1
                fiveHourColor: root.windowColor(root.entry.usage?.fiveHour)
                sevenDayColor: root.windowColor(root.entry.usage?.sevenDay)
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.pillText
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.DemiBold
                font.features: ({"tnum": 1})
                color: root.accentFor(root.provider)
            }

            LiveDot {
                anchors.verticalCenter: parent.verticalCenter
                live: root.entry.live
                color: root.accentFor(root.provider)
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            LimitRing {
                anchors.horizontalCenter: parent.horizontalCenter
                size: Theme.iconSize - 6
                fiveHourPct: root.entry.usage ? root.entry.usage.fiveHour.pct : -1
                sevenDayPct: root.entry.usage ? root.entry.usage.sevenDay.pct : -1
                fiveHourColor: root.windowColor(root.entry.usage?.fiveHour)
                sevenDayColor: root.windowColor(root.entry.usage?.sevenDay)
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.pillText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold
                font.features: ({"tnum": 1})
                color: root.accentFor(root.provider)
            }
        }
    }

    popoutWidth: 340

    popoutContent: Component {
        Column {
            id: panel

            readonly property real innerWidth: width - leftPadding - rightPadding
            readonly property var selected: root.providers.find(item => item.id === root.provider)

            padding: Theme.spacingS
            spacing: Theme.spacingM + 2

            Component.onCompleted: root.refreshAll()

            // Provider tabs (segmented control)
            Rectangle {
                width: panel.innerWidth
                height: 38
                radius: 12
                color: Theme.withAlpha(Theme.surfaceText, 0.06)

                Row {
                    id: tabs

                    readonly property real gap: 3

                    anchors.fill: parent
                    anchors.margins: gap
                    spacing: gap

                    Repeater {
                        model: root.providers

                        Rectangle {
                            id: tab

                            required property var modelData
                            readonly property bool checked: root.provider === modelData.id

                            width: (tabs.width - tabs.gap * (root.providers.length - 1)) / root.providers.length
                            height: tabs.height
                            radius: 9
                            color: {
                                if (checked)
                                    return Theme.withAlpha(root.accentFor(modelData.id), 0.9);
                                return Theme.withAlpha(Theme.surfaceText, tabArea.containsMouse ? 0.06 : 0);
                            }
                            border.width: activeFocus ? 1 : 0
                            border.color: Theme.withAlpha(Theme.surfaceText, 0.35)
                            activeFocusOnTab: true

                            Keys.onReturnPressed: root.selectProvider(modelData.id)
                            Keys.onSpacePressed: root.selectProvider(modelData.id)

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                }
                            }

                            StyledText {
                                anchors.centerIn: parent
                                text: tab.modelData.label
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.DemiBold
                                color: {
                                    if (tab.checked)
                                        return root.textOnAccent(tab.modelData.id);
                                    return Theme.withAlpha(Theme.surfaceText, tabArea.containsMouse ? 1 : 0.55);
                                }
                            }

                            MouseArea {
                                id: tabArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectProvider(tab.modelData.id)
                            }
                        }
                    }
                }
            }

            // Header: title, plan badge, live status
            Item {
                width: panel.innerWidth
                height: title.implicitHeight

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    StyledText {
                        id: title

                        text: panel.selected.title
                        font.pixelSize: Theme.fontSizeLarge + 2
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: plan.implicitWidth + 12
                        height: plan.implicitHeight + 4
                        radius: 6
                        color: Theme.withAlpha(Theme.surfaceText, 0.08)
                        visible: plan.text.length > 0

                        StyledText {
                            id: plan

                            anchors.centerIn: parent
                            text: root.entry.usage?.plan ? root.entry.usage.plan.toUpperCase() : ""
                            font.pixelSize: Theme.fontSizeSmall - 2
                            font.weight: Font.Bold
                            color: Theme.withAlpha(Theme.surfaceText, 0.7)
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    LiveDot {
                        anchors.verticalCenter: parent.verticalCenter
                        live: root.entry.live
                        color: root.accentFor(root.provider)
                    }

                    StyledText {
                        readonly property bool blocked: root.entry.usage?.status === "blocked"

                        text: blocked ? "Limit reached" : root.entry.live ? "Running" : "Idle"
                        font.pixelSize: Theme.fontSizeSmall
                        color: blocked ? root.criticalColor : Theme.withAlpha(Theme.surfaceText, 0.55)
                    }
                }
            }

            LimitRow {
                width: panel.innerWidth
                title: "5-hour session"
                usageWindow: root.entry.usage?.fiveHour ?? null
                now: root.now
                accentColor: root.accentFor(root.provider)
                criticalColor: root.criticalColor
            }

            LimitRow {
                width: panel.innerWidth
                title: "Weekly (7 days)"
                usageWindow: root.entry.usage?.sevenDay ?? null
                now: root.now
                accentColor: root.accentFor(root.provider)
                criticalColor: root.criticalColor
            }

            Rectangle {
                width: panel.innerWidth
                height: errorText.implicitHeight + 16
                radius: 10
                color: Theme.withAlpha(root.criticalColor, 0.12)
                visible: !!root.entry.error

                StyledText {
                    id: errorText

                    anchors.fill: parent
                    anchors.margins: 8
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    text: root.entry.error ?? ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.isLightMode ? "#b91c1c" : "#fca5a5"
                    wrapMode: Text.WordWrap
                }
            }

            // Footer: data age and manual refresh
            Item {
                width: panel.innerWidth
                height: refreshButton.height + Theme.spacingS

                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: Theme.withAlpha(Theme.surfaceText, 0.07)
                }

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: refreshButton.verticalCenter
                    text: {
                        if (root.loading)
                            return "Updating…";
                        if (!root.entry.usage)
                            return "No data";
                        return "Updated " + Format.formatAge(root.entry.usage.dataAt, root.now);
                    }
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.withAlpha(Theme.surfaceText, 0.5)
                }

                Rectangle {
                    id: refreshButton

                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    width: 30
                    height: 30
                    radius: 15
                    color: Theme.withAlpha(Theme.surfaceText, refreshArea.pressed ? 0.16 : refreshArea.containsMouse ? 0.1 : 0)
                    border.width: activeFocus ? 1 : 0
                    border.color: Theme.withAlpha(Theme.surfaceText, 0.35)
                    activeFocusOnTab: true

                    Keys.onReturnPressed: root.refresh(root.provider, true)
                    Keys.onSpacePressed: root.refresh(root.provider, true)

                    DankIcon {
                        id: refreshIcon

                        anchors.centerIn: parent
                        name: "refresh"
                        size: Theme.iconSize - 6
                        color: Theme.withAlpha(Theme.surfaceText, root.loading ? 0.3 : refreshArea.containsMouse ? 1 : 0.7)

                        RotationAnimation on rotation {
                            running: root.loading
                            loops: Animation.Infinite
                            from: 0
                            to: 360
                            duration: 900
                            onRunningChanged: {
                                if (!running)
                                    refreshIcon.rotation = 0;
                            }
                        }
                    }

                    MouseArea {
                        id: refreshArea

                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !root.loading
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.now = root.nowSecs();
                            root.refresh(root.provider, true);
                        }
                    }
                }
            }
        }
    }
}
