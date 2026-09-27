// Drop-down panel content: provider tabs, two limit rows, footer.
import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {formatAge, formatReset, levelFor} from './format.js';

export const PROVIDERS = [
    {id: 'claude', label: 'Claude', title: 'Claude Code'},
    {id: 'codex', label: 'GPT', title: 'Codex (ChatGPT)'},
];

const BAR_WIDTH = 272;

const LimitRow = GObject.registerClass(
class LimitRow extends St.BoxLayout {
    _init(title) {
        super._init({style_class: 'ailc-limit', vertical: true, x_expand: true});

        const head = new St.BoxLayout({style_class: 'ailc-limit-head'});
        head.add_child(new St.Label({text: title, style_class: 'ailc-limit-title', y_align: Clutter.ActorAlign.END}));
        head.add_child(new St.Widget({x_expand: true}));
        this._pct = new St.Label({text: '—', style_class: 'ailc-limit-pct'});
        head.add_child(this._pct);
        this.add_child(head);

        this._track = new St.Widget({style_class: 'ailc-bar', width: BAR_WIDTH});
        this._fill = new St.Widget({style_class: 'ailc-bar-fill', width: 0});
        this._track.add_child(this._fill);
        this.add_child(this._track);

        this._reset = new St.Label({text: ' ', style_class: 'ailc-limit-reset'});
        this.add_child(this._reset);
    }

    /**
     * @param {{pct:number, resetAt:number}|null} window
     * @param {string} provider id; the bar uses its accent color unless usage is critical
     */
    update(window, now, provider) {
        const isCritical = window !== null && levelFor(window.pct) === 'crit';
        this._pct.text = window ? `${window.pct}%` : '—';
        this._fill.width = window ? Math.round(BAR_WIDTH * Math.min(window.pct, 100) / 100) : 0;
        this._fill.style_class = `ailc-bar-fill ailc-accent-bg-${isCritical ? 'crit' : provider}`;
        this._pct.style_class = `ailc-limit-pct${isCritical ? ' ailc-accent-fg-crit' : ''}`;

        const remaining = window ? formatReset(window.resetAt, now) : null;
        if (!window)
            this._reset.text = ' ';
        else if (remaining === null)
            this._reset.text = 'Window has reset';
        else
            this._reset.text = `Resets in ${remaining}`;
    }
});

export const LimitPanel = GObject.registerClass({
    Signals: {
        'provider-selected': {param_types: [GObject.TYPE_STRING]},
        'refresh-requested': {},
    },
}, class LimitPanel extends St.BoxLayout {
    _init() {
        super._init({style_class: 'ailc-panel', vertical: true});
        this._tabs = new Map();

        this.add_child(this._buildTabs());
        this.add_child(this._buildHeader());

        this._fiveHour = new LimitRow('5-hour session');
        this._sevenDay = new LimitRow('Weekly (7 days)');
        this.add_child(this._fiveHour);
        this.add_child(this._sevenDay);

        this._error = new St.Label({style_class: 'ailc-error', visible: false});
        this._error.clutter_text.line_wrap = true;
        this.add_child(this._error);

        this.add_child(this._buildFooter());
    }

    _buildTabs() {
        const tabs = new St.BoxLayout({style_class: 'ailc-tabs', x_expand: true});
        for (const provider of PROVIDERS) {
            const button = new St.Button({
                label: provider.label,
                style_class: `ailc-tab ailc-tab-${provider.id}`,
                x_expand: true,
                can_focus: true,
                toggle_mode: false,
            });
            button.connect('clicked', () => this.emit('provider-selected', provider.id));
            this._tabs.set(provider.id, button);
            tabs.add_child(button);
        }
        return tabs;
    }

    _buildHeader() {
        const header = new St.BoxLayout({style_class: 'ailc-header'});
        this._title = new St.Label({style_class: 'ailc-title', y_align: Clutter.ActorAlign.CENTER});
        this._plan = new St.Label({style_class: 'ailc-plan', y_align: Clutter.ActorAlign.CENTER, visible: false});
        this._plan.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
        header.add_child(this._title);
        header.add_child(this._plan);
        header.add_child(new St.Widget({x_expand: true}));
        this._liveDot = new St.Widget({style_class: 'ailc-live-dot', y_align: Clutter.ActorAlign.CENTER});
        this._status = new St.Label({style_class: 'ailc-status', y_align: Clutter.ActorAlign.CENTER});
        header.add_child(this._liveDot);
        header.add_child(this._status);
        return header;
    }

    _buildFooter() {
        const footer = new St.BoxLayout({style_class: 'ailc-footer'});
        this._updated = new St.Label({style_class: 'ailc-updated', y_align: Clutter.ActorAlign.CENTER});
        footer.add_child(this._updated);
        footer.add_child(new St.Widget({x_expand: true}));
        this._refresh = new St.Button({
            style_class: 'ailc-refresh',
            can_focus: true,
            child: new St.Icon({icon_name: 'view-refresh-symbolic', icon_size: 14}),
            accessible_name: 'Refresh',
        });
        this._refresh.connect('clicked', () => this.emit('refresh-requested'));
        footer.add_child(this._refresh);
        return footer;
    }

    /**
     * @param {string} selected provider id
     * @param {{usage:object|null, error:string|null, live:boolean, loading:boolean}} entry
     */
    render(selected, entry, now) {
        for (const [id, button] of this._tabs) {
            if (id === selected)
                button.add_style_pseudo_class('checked');
            else
                button.remove_style_pseudo_class('checked');
        }

        const provider = PROVIDERS.find(p => p.id === selected);
        const {usage, error, live, loading} = entry;
        this._title.text = provider.title;
        this._plan.text = usage?.plan ? usage.plan.toUpperCase() : '';
        this._plan.visible = Boolean(usage?.plan);

        this._liveDot.visible = live;
        this._liveDot.style_class = `ailc-live-dot ailc-accent-bg-${selected}`;
        this._status.text = this._statusText(usage, live);
        this._status.style_class = `ailc-status${usage?.status === 'blocked' ? ' ailc-accent-fg-crit' : ''}`;

        this._fiveHour.update(usage?.fiveHour ?? null, now, selected);
        this._sevenDay.update(usage?.sevenDay ?? null, now, selected);

        this._error.text = error ?? '';
        this._error.visible = Boolean(error);

        this._updated.text = this._updatedText(usage, loading, now);
        this._refresh.reactive = !loading;
    }

    _statusText(usage, live) {
        if (usage?.status === 'blocked')
            return 'Limit reached';
        return live ? 'Running' : 'Idle';
    }

    _updatedText(usage, loading, now) {
        if (loading)
            return 'Updating…';
        if (!usage)
            return 'No data';
        return `Updated ${formatAge(usage.dataAt, now)}`;
    }
});
