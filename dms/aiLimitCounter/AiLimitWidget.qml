import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "format.js" as Format

// Bar pill (ring + percentage) and drop-down panel. State and polling live in LimitService.
PluginComponent {
    id: root

    readonly property var providers: LimitService.providers
    readonly property string provider: pluginData.provider === "codex" ? "codex" : "claude"
    readonly property string helperPath: Format.expandHome(pluginData.helperPath || "~/.local/bin/ai-limit-counter", Quickshell.env("HOME"))

    readonly property var entry: LimitService.entries[provider]
    readonly property bool loading: LimitService.loading
    readonly property int now: LimitService.now
    // Typed as colors (not strings) so Theme.withAlpha can read their channels.
    readonly property color claudeAccent: "#d97757"
    readonly property color codexAccent: Theme.isLightMode ? "#1b1b1f" : "#f4f4f6"
    readonly property color textOnClaude: "#ffffff"
    readonly property color textOnCodex: Theme.isLightMode ? "#ffffff" : "#111114"
    readonly property color criticalColor: "#f87171"
    readonly property color idleColor: "#9e9ea8"
    readonly property string pillText: entry.usage ? entry.usage.fiveHour.pct + "%" : entry.error ? "!" : "…"

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

    function selectProvider(id) {
        if (id === provider || !pluginService)
            return;
        pluginService.savePluginData(pluginId, "provider", id);
    }

    onProviderChanged: LimitService.provider = provider
    onHelperPathChanged: LimitService.helperPath = helperPath
    Component.onCompleted: LimitService.attach(provider, helperPath)
    Component.onDestruction: LimitService.detach()

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

            Component.onCompleted: LimitService.refreshAll()

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

                    Keys.onReturnPressed: LimitService.refresh(root.provider, true)
                    Keys.onSpacePressed: LimitService.refresh(root.provider, true)

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
                        onClicked: LimitService.refresh(root.provider, true)
                    }
                }
            }
        }
    }
}
