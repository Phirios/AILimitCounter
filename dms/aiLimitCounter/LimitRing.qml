import QtQuick
import QtQuick.Shapes

// Bar icon: outer ring = 5h window, inner disc filling bottom-up = 7d window.
Item {
    id: root

    property real size: 18
    /** Percent used, or a negative value when there is no data yet. */
    property real fiveHourPct: -1
    property real sevenDayPct: -1
    property color fiveHourColor: "#9e9ea8"
    property color sevenDayColor: "#9e9ea8"

    readonly property real trackAlpha: 0.22
    readonly property real ringWidth: Math.max(1.5, size * 0.14)
    readonly property real ringRadius: size / 2 - ringWidth / 2
    readonly property real discRadius: ringRadius - ringWidth / 2 - size * 0.12
    readonly property real fiveHourFraction: Math.min(Math.max(fiveHourPct, 0), 100) / 100
    readonly property real sevenDayFraction: Math.min(Math.max(sevenDayPct, 0), 100) / 100
    /** Half of the angle covered by the filled segment of the disc, in degrees. */
    readonly property real discHalfAngle: Math.acos(1 - 2 * sevenDayFraction) * 180 / Math.PI

    function faded(color) {
        return Qt.rgba(color.r, color.g, color.b, trackAlpha);
    }

    implicitWidth: size
    implicitHeight: size

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: root.faded(root.fiveHourColor)
            strokeWidth: root.ringWidth
            fillColor: "transparent"

            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: root.ringRadius
                radiusY: root.ringRadius
                startAngle: 0
                sweepAngle: 360
            }
        }

        ShapePath {
            strokeColor: root.fiveHourFraction > 0 ? root.fiveHourColor : "transparent"
            strokeWidth: root.ringWidth
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap

            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: root.ringRadius
                radiusY: root.ringRadius
                startAngle: -90
                sweepAngle: 360 * root.fiveHourFraction
            }
        }

        ShapePath {
            strokeColor: "transparent"
            strokeWidth: 0
            fillColor: root.faded(root.sevenDayColor)

            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: root.discRadius
                radiusY: root.discRadius
                startAngle: 0
                sweepAngle: 360
            }
        }

        // The arc is closed by its chord, which is the top edge of the fill level.
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: 0
            fillColor: root.sevenDayFraction > 0 ? root.sevenDayColor : "transparent"

            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: root.discRadius
                radiusY: root.discRadius
                startAngle: 90 - root.discHalfAngle
                sweepAngle: 2 * root.discHalfAngle
            }
        }
    }
}
