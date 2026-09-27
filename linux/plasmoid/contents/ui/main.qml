import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    property int fiveHPct: 0
    property int sevenDPct: 0
    property double fiveHReset: 0
    property double sevenDReset: 0
    property bool isLive: false
    property string providerName: "Codex"
    property string usageStatus: "unknown"
    property string errorText: ""
    property string sourceText: ""
    property double fetchedAt: 0
    property double nowSeconds: Date.now() / 1000
    readonly property string statusUrl: "http://127.0.0.1:38465/status"
    readonly property real remainingRatio: Math.max(0, Math.min(1,
        (fiveHReset - nowSeconds) / (5 * 60 * 60)))

    implicitWidth: Kirigami.Units.gridUnit * 4.25
    implicitHeight: Kirigami.Units.gridUnit * 1.5
    Layout.minimumWidth: implicitWidth
    Layout.preferredWidth: implicitWidth

    function usageColor(percent) {
        if (percent >= 85) return "#dc3232"
        if (percent >= 70) return "#e68228"
        if (percent >= 55) return "#c8b428"
        return "#3cb450"
    }

    function relativeTime(timestamp) {
        const seconds = Math.max(0, Math.floor(timestamp - root.nowSeconds))
        const hours = Math.floor(seconds / 3600)
        const minutes = Math.floor((seconds % 3600) / 60)
        return hours > 0 ? "in " + hours + "h " + minutes + "m" : "in " + minutes + "m"
    }

    function applyOutput(output) {
        try {
            const parsed = JSON.parse(output)
            providerName = parsed.provider || "Codex"
            isLive = parsed.is_live || false
            errorText = parsed.error || ""
            if (errorText.length === 0) {
                fiveHPct = parsed.five_h_pct || 0
                sevenDPct = parsed.seven_d_pct || 0
                fiveHReset = parsed.five_h_reset || 0
                sevenDReset = parsed.seven_d_reset || 0
                usageStatus = parsed.status || "unknown"
                sourceText = parsed.source || ""
                fetchedAt = parsed.fetched_at || 0
            }
        } catch (error) {
            errorText = "Could not read usage data"
        }
    }

    function refresh() {
        const request = new XMLHttpRequest()
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE) return
            if (request.status === 200) {
                root.applyOutput(request.responseText)
            } else {
                root.errorText = "AI Limit Counter service unavailable"
            }
        }
        request.open("GET", statusUrl + "?t=" + Date.now())
        request.send()
    }

    toolTipMainText: errorText.length > 0
                     ? "AI Limit Counter"
                     : providerName + "  " + fiveHPct + "% / " + sevenDPct + "%"
    toolTipSubText: errorText.length > 0
                    ? errorText
                    : "5h resets " + relativeTime(fiveHReset)
    preferredRepresentation: compactRepresentation

    Component.onCompleted: refresh()

    Timer {
        interval: root.isLive ? 60000 : 300000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.nowSeconds = Date.now() / 1000
    }

    compactRepresentation: Item {
        id: compact
        implicitWidth: Kirigami.Units.gridUnit * 4.25
        implicitHeight: Kirigami.Units.gridUnit * 1.5
        Layout.minimumWidth: implicitWidth
        Layout.preferredWidth: implicitWidth

        Canvas {
            id: compactCanvas
            width: Math.min(parent.height - 4, Kirigami.Units.iconSizes.smallMedium)
            height: width
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.verticalCenter: parent.verticalCenter

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                if (width < 12 || height < 12) return
                const center = width / 2
                const outerRadius = width / 2 - 2
                const innerRadius = outerRadius - 4

                ctx.lineWidth = 3
                ctx.strokeStyle = Qt.rgba(0.55, 0.55, 0.55, 0.35)
                ctx.beginPath()
                ctx.arc(center, center, outerRadius, 0, Math.PI * 2)
                ctx.stroke()

                if (root.fiveHPct > 0) {
                    ctx.strokeStyle = root.usageColor(root.fiveHPct)
                    ctx.lineCap = "round"
                    ctx.beginPath()
                    ctx.arc(center, center, outerRadius, -Math.PI / 2,
                            -Math.PI / 2 + Math.PI * 2 * Math.min(100, root.fiveHPct) / 100)
                    ctx.stroke()
                }

                ctx.fillStyle = Qt.rgba(0.55, 0.55, 0.55, 0.2)
                ctx.beginPath()
                ctx.arc(center, center, innerRadius, 0, Math.PI * 2)
                ctx.fill()

                if (root.sevenDPct > 0) {
                    ctx.save()
                    ctx.beginPath()
                    ctx.arc(center, center, innerRadius, 0, Math.PI * 2)
                    ctx.clip()
                    const fillHeight = innerRadius * 2 * Math.min(100, root.sevenDPct) / 100
                    ctx.fillStyle = root.usageColor(root.sevenDPct)
                    ctx.fillRect(center - innerRadius, center + innerRadius - fillHeight,
                                 innerRadius * 2, fillHeight)
                    ctx.restore()
                }
            }

            Connections {
                target: root
                function onFiveHPctChanged() { compactCanvas.requestPaint() }
                function onSevenDPctChanged() { compactCanvas.requestPaint() }
            }
        }

        Column {
            anchors.left: compactCanvas.right
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.right: liveDot.left
            anchors.rightMargin: root.isLive ? Kirigami.Units.smallSpacing : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            PlasmaComponents.Label {
                width: parent.width
                text: root.errorText.length > 0 ? "--%" : root.fiveHPct + "%"
                color: root.usageColor(root.fiveHPct)
                font.weight: Font.DemiBold
                font.family: "monospace"
                fontSizeMode: Text.Fit
                minimumPixelSize: 8
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
                width: parent.width
                height: 3
                radius: 1.5
                color: Qt.rgba(0.55, 0.55, 0.55, 0.35)

                Rectangle {
                    width: parent.width * root.remainingRatio
                    height: parent.height
                    radius: parent.radius
                    color: "#3cb450"
                }
            }
        }

        Rectangle {
            id: liveDot
            visible: root.isLive
            width: 5
            height: 5
            radius: width / 2
            color: "#217ae8"
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter

            SequentialAnimation on opacity {
                running: root.isLive
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 850 }
                NumberAnimation { to: 1.0; duration: 850 }
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: implicitHeight
        Layout.preferredHeight: implicitHeight
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            text: root.providerName + (root.isLive ? " is running" : " is idle")
            font.bold: true
        }

        PlasmaComponents.Label {
            visible: root.errorText.length > 0
            text: root.errorText
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        PlasmaComponents.Label {
            visible: root.errorText.length === 0
            text: root.usageStatus === "allowed" ? "✅ Allowed" : "🔴 Blocked"
        }

        PlasmaComponents.Label {
            visible: root.errorText.length === 0
            text: "5h   " + root.fiveHPct + "%"
            color: root.usageColor(root.fiveHPct)
            font.family: "monospace"
            font.bold: true
        }

        PlasmaComponents.ProgressBar {
            visible: root.errorText.length === 0
            from: 0
            to: 100
            value: root.fiveHPct
            Layout.fillWidth: true
        }

        PlasmaComponents.Label {
            visible: root.errorText.length === 0
            text: "Resets " + root.relativeTime(root.fiveHReset)
        }

        PlasmaComponents.Label {
            visible: root.errorText.length === 0
            text: "7d   " + root.sevenDPct + "%"
            color: root.usageColor(root.sevenDPct)
            font.family: "monospace"
            font.bold: true
        }

        PlasmaComponents.ProgressBar {
            visible: root.errorText.length === 0
            from: 0
            to: 100
            value: root.sevenDPct
            Layout.fillWidth: true
        }

        PlasmaComponents.Label {
            visible: root.errorText.length === 0
            text: "Resets " + root.relativeTime(root.sevenDReset)
        }

        PlasmaComponents.Button {
            text: "Refresh Now"
            onClicked: root.refresh()
            Layout.alignment: Qt.AlignRight
        }
    }
}
