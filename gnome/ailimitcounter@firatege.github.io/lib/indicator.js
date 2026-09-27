// Top-bar button: ring + percentage, owns the refresh schedule and per-provider state.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Soup from 'gi://Soup?version=3.0';
import St from 'gi://St';

import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {levelFor} from './format.js';
import {LimitPanel, PROVIDERS} from './panel.js';
import {LimitRing} from './ring.js';
import {SourceError, fetchClaude, fetchCodex, isClaudeRunning, nowSecs} from './sources.js';

const TICK_SECS = 60;
/** Each Claude check spends ~10 Haiku tokens, so poll it gently. */
const CLAUDE_IDLE_INTERVAL_SECS = 300;
const CLAUDE_LIVE_INTERVAL_SECS = 60;
const CLAUDE_MIN_AGE_SECS = 60;
const PULSE_MS = 900;
const PULSE_MIN_OPACITY = 70;

const EMPTY_ENTRY = Object.freeze({usage: null, error: null, live: false, loading: false, fetchedAt: 0});

function isCancelled(e) {
    return e?.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED) ?? false;
}

export const LimitIndicator = GObject.registerClass(
class LimitIndicator extends PanelMenu.Button {
    _init(settings) {
        super._init(0.5, 'AI Limit Counter');
        this._settings = settings;
        this._entries = Object.fromEntries(PROVIDERS.map(p => [p.id, EMPTY_ENTRY]));
        this._cancellable = new Gio.Cancellable();
        this._session = new Soup.Session({timeout: 20});

        this._buildButton();
        this._buildMenu();

        this._settingsId = settings.connect('changed::provider', () => {
            this._render();
            this._refresh(this._selected());
        });
        this._timerId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, TICK_SECS, () => {
            this._tick();
            return GLib.SOURCE_CONTINUE;
        });

        this._render();
        this._tick({initial: true});
    }

    _buildButton() {
        const box = new St.BoxLayout({style_class: 'ailc-button'});
        this._ring = new LimitRing();
        this._label = new St.Label({text: '…', style_class: 'ailc-button-label', y_align: Clutter.ActorAlign.CENTER});
        this._buttonDot = new St.Widget({style_class: 'ailc-live-dot ailc-button-dot', y_align: Clutter.ActorAlign.CENTER});
        box.add_child(this._ring);
        box.add_child(this._label);
        box.add_child(this._buttonDot);
        this.add_child(box);
    }

    _buildMenu() {
        this.menu.actor.add_style_class_name('ailc-menu');
        this._panel = new LimitPanel();
        this._panel.connect('provider-selected', (_panel, id) => this._settings.set_string('provider', id));
        this._panel.connect('refresh-requested', () => this._refresh(this._selected(), {force: true}));

        const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        item.add_style_class_name('ailc-item');
        item.add_child(this._panel);
        this.menu.addMenuItem(item);

        this.menu.connect('open-state-changed', (_menu, open) => {
            if (!open)
                return;
            this._render();
            for (const {id} of PROVIDERS)
                this._refresh(id);
        });
    }

    _selected() {
        const id = this._settings.get_string('provider');
        return PROVIDERS.some(p => p.id === id) ? id : PROVIDERS[0].id;
    }

    _setEntry(id, changes) {
        if (this._destroyed)
            return;
        this._entries = {...this._entries, [id]: {...this._entries[id], ...changes}};
        this._render();
    }

    async _tick({initial = false} = {}) {
        try {
            const claudeLive = await isClaudeRunning(this._cancellable);
            this._setEntry('claude', {live: claudeLive});
        } catch (e) {
            if (isCancelled(e))
                return;
            logError(e, 'AILimitCounter: liveness check failed');
        }

        // Codex reads local files only, so it is always cheap to refresh.
        this._refresh('codex');

        const claude = this._entries.claude;
        const interval = claude.live ? CLAUDE_LIVE_INTERVAL_SECS : CLAUDE_IDLE_INTERVAL_SECS;
        const claudeDue = nowSecs() - claude.fetchedAt >= interval;
        if (this._selected() === 'claude' && (initial || claudeDue))
            this._refresh('claude');
        else
            this._render();
    }

    async _refresh(id, {force = false} = {}) {
        const entry = this._entries[id];
        if (entry.loading)
            return;
        if (id === 'claude' && !force && nowSecs() - entry.fetchedAt < CLAUDE_MIN_AGE_SECS)
            return;

        this._setEntry(id, {loading: true});
        try {
            const usage = id === 'claude'
                ? await fetchClaude(this._session, this._cancellable)
                : await fetchCodex(this._cancellable);
            const live = id === 'codex' ? usage.live : this._entries[id].live;
            this._setEntry(id, {usage, live, error: null, loading: false, fetchedAt: nowSecs()});
        } catch (e) {
            if (isCancelled(e))
                return;
            if (!(e instanceof SourceError))
                logError(e, `AILimitCounter: ${id} refresh failed`);
            const message = e instanceof SourceError ? e.message : `Connection error: ${e.message}`;
            this._setEntry(id, {error: message, loading: false, fetchedAt: nowSecs()});
        }
    }

    _render() {
        if (!this._panel || this._destroyed)
            return;
        const now = nowSecs();
        const selected = this._selected();
        const entry = this._entries[selected];
        const {usage} = entry;

        const toRingWindow = w =>
            (w ? {pct: w.pct, color: levelFor(w.pct) === 'crit' ? 'crit' : selected} : null);
        this._ring.setWindows(toRingWindow(usage?.fiveHour), toRingWindow(usage?.sevenDay));
        this._label.text = usage ? `${usage.fiveHour.pct}%` : entry.error ? '!' : '…';
        this._label.style_class = `ailc-button-label ailc-accent-fg-${selected}`;
        this._buttonDot.style_class = `ailc-live-dot ailc-button-dot ailc-accent-bg-${selected}`;
        this._setPulse(this._buttonDot, entry.live);

        if (this.menu.isOpen)
            this._panel.render(selected, entry, now);
    }

    _setPulse(dot, live) {
        if (dot.visible === live)
            return;
        dot.visible = live;
        dot.remove_all_transitions();
        dot.opacity = 255;
        if (live) {
            dot.ease({
                opacity: PULSE_MIN_OPACITY,
                duration: PULSE_MS,
                mode: Clutter.AnimationMode.EASE_IN_OUT_SINE,
                repeatCount: -1,
                autoReverse: true,
            });
        }
    }

    destroy() {
        // Async work that settles after this point must not touch destroyed actors.
        this._destroyed = true;
        this._cancellable.cancel();
        if (this._timerId) {
            GLib.Source.remove(this._timerId);
            this._timerId = 0;
        }
        if (this._settingsId) {
            this._settings.disconnect(this._settingsId);
            this._settingsId = 0;
        }
        this._session.abort();
        super.destroy();
    }
});
