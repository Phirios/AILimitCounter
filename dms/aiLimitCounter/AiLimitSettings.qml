import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "aiLimitCounter"

    SelectionSetting {
        settingKey: "provider"
        label: "Provider"
        description: "Which assistant the bar shows; the panel can switch between both"
        options: [
            {
                label: "Claude",
                value: "claude"
            },
            {
                label: "GPT (Codex)",
                value: "codex"
            }
        ]
        defaultValue: "claude"
    }

    StringSetting {
        settingKey: "helperPath"
        label: "Helper path"
        description: "Location of the ai-limit-counter binary; leave empty for ~/.local/bin/ai-limit-counter"
        placeholder: "~/.local/bin/ai-limit-counter"
    }
}
