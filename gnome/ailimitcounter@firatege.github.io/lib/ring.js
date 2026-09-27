// Panel icon: outer ring = 5h window, inner disc filling bottom-up = 7d window.
import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

/** Keep in sync with the `.ailc-accent-*` colors in stylesheet.css. */
export const ACCENT_RGB = {
    claude: [0.851, 0.467, 0.341],
    codex: [0.957, 0.957, 0.965],
    crit: [0.973, 0.443, 0.443],
    idle: [0.62, 0.62, 0.66],
};

const TRACK_ALPHA = 0.22;
const RING_WIDTH_RATIO = 0.14;
const INNER_GAP_RATIO = 0.12;

export const LimitRing = GObject.registerClass(
class LimitRing extends St.DrawingArea {
    _init(params = {}) {
        super._init({style_class: 'ailc-ring', y_align: Clutter.ActorAlign.CENTER, ...params});
        this._fiveHour = null;
        this._sevenDay = null;
        this.connect('repaint', () => this._draw());
    }

    /** @param {{pct:number, color:string}|null} fiveHour @param {{pct:number, color:string}|null} sevenDay */
    setWindows(fiveHour, sevenDay) {
        this._fiveHour = fiveHour;
        this._sevenDay = sevenDay;
        this.queue_repaint();
    }

    _draw() {
        const cr = this.get_context();
        const [width, height] = this.get_surface_size();
        const size = Math.min(width, height);
        const cx = width / 2;
        const cy = height / 2;
        const lineWidth = Math.max(1.5, size * RING_WIDTH_RATIO);
        const radius = size / 2 - lineWidth / 2;
        const innerRadius = radius - lineWidth / 2 - size * INNER_GAP_RATIO;

        const [fr, fg, fb] = ACCENT_RGB[this._fiveHour?.color ?? 'idle'];
        cr.setLineWidth(lineWidth);
        cr.setSourceRGBA(fr, fg, fb, TRACK_ALPHA);
        cr.arc(cx, cy, radius, 0, 2 * Math.PI);
        cr.stroke();

        if (this._fiveHour?.pct > 0) {
            const start = -Math.PI / 2;
            cr.setSourceRGBA(fr, fg, fb, 1);
            cr.arc(cx, cy, radius, start, start + 2 * Math.PI * Math.min(this._fiveHour.pct, 100) / 100);
            cr.stroke();
        }

        const [sr, sg, sb] = ACCENT_RGB[this._sevenDay?.color ?? 'idle'];
        cr.arc(cx, cy, innerRadius, 0, 2 * Math.PI);
        cr.setSourceRGBA(sr, sg, sb, TRACK_ALPHA);
        cr.fillPreserve();
        cr.clip();
        const fillHeight = 2 * innerRadius * Math.min(this._sevenDay?.pct ?? 0, 100) / 100;
        cr.rectangle(cx - innerRadius, cy + innerRadius - fillHeight, 2 * innerRadius, fillHeight);
        cr.setSourceRGBA(sr, sg, sb, 1);
        cr.fill();

        cr.$dispose();
    }
});
