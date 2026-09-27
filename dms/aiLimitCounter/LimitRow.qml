import QtQuick
import qs.Common
import qs.Widgets
import "format.js" as Format

// One usage window: title, percentage, progress bar and time until reset.
Column {
    id: root

    required property string title
    /** {pct, resetAt} or null while there is no data. */
    property var usageWindow: null
    property int now: 0
    property color accentColor: Theme.primary
    property color criticalColor: Theme.error

    readonly property bool hasData: usageWindow !== null && usageWindow !== undefined
    readonly property bool isCritical: hasData && Format.levelFor(usageWindow.pct) === "crit"
    readonly property real fraction: hasData ? Math.min(Math.max(usageWindow.pct, 0), 100) / 100 : 0
    readonly property string resetText: {
        if (!hasData)
            return " ";
        const remaining = Format.formatReset(usageWindow.resetAt, now);
        return remaining === null ? "Window has reset" : "Resets in " + remaining;
    }

    spacing: 6

    Item {
        width: parent.width
        height: percent.implicitHeight

        StyledText {
            anchors.left: parent.left
            anchors.baseline: percent.baseline
            text: root.title
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            id: percent
            anchors.right: parent.right
            text: root.hasData ? root.usageWindow.pct + "%" : "—"
            font.pixelSize: Theme.fontSizeXLarge + 6
            font.weight: Font.Bold
            font.features: ({"tnum": 1})
            color: root.isCritical ? root.criticalColor : Theme.surfaceText
        }
    }

    Rectangle {
        width: parent.width
        height: 6
        radius: 3
        color: Theme.withAlpha(Theme.surfaceText, 0.09)

        Rectangle {
            width: parent.width * root.fraction
            height: parent.height
            radius: parent.radius
            color: root.isCritical ? root.criticalColor : root.accentColor
            visible: root.fraction > 0

            Behavior on width {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }
        }
    }

    StyledText {
        text: root.resetText
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.withAlpha(Theme.surfaceText, 0.5)
    }
}
