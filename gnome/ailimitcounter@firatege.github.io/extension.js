import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {LimitIndicator} from './lib/indicator.js';

export default class AILimitCounterExtension extends Extension {
    enable() {
        this._indicator = new LimitIndicator(this.getSettings());
        Main.panel.addToStatusArea(this.uuid, this._indicator, 0, 'right');
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
