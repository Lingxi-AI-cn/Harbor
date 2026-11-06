# Appearance

Choose **Harbor → Appearance**: Follow System (default), Light or Dark. Changes apply immediately and persist. System mode inherits macOS appearance automatically; it does not modify system preferences.

New terminal profiles use **Follow Appearance**. Previously saved explicit themes remain unchanged. The Ghostty terminal preferences panel applies its theme selection to new terminals. Existing terminals following the interface update colors without restarting their shell or rereading unrelated preferences.

AppKit dynamic colors update native controls; custom layers refresh when effective appearance changes. Explicit terminal truecolor output and remote desktop pixels remain controlled by the programs producing them.

See [verification](VERIFICATION.md) for checks and their scope.
