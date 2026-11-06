import Foundation
var failures = 0
func check(_ ok: Bool,_ description: String) { print("\(ok ? "PASS" : "FAIL"): \(description)"); if !ok { failures += 1 } }
let defaults = Dictionary(uniqueKeysWithValues:TerminalPreferences.shortcutActions.map { ($0.id,$0.defaultKey) })
check((try? TerminalPreferences.validateShortcuts(defaults)) != nil,"all default actions and shifted plus alias validate")
var custom = defaults; custom["zoomIn"] = "shift+cmd+j"
check((try? TerminalPreferences.validateShortcuts(custom)) != nil,"custom modifier order is accepted")
custom["zoomOut"] = "cmd+shift+j"
check((try? TerminalPreferences.validateShortcuts(custom)) == nil,"equivalent duplicate shortcuts are rejected across actions")
for value in ["cmd+f","cmd+d","cmd+shift+d","cmd+t","cmd+shift+q","ctrl+c","cmd+cmd+j","cmd+","cmd+é","cmd+j,","cmd+j,cmd+j"] {
    var values = defaults; values["zoomIn"] = value
    check((try? TerminalPreferences.validateShortcuts(values)) == nil,"reject reserved or malformed binding: \(value)")
}
var missing = defaults; missing.removeValue(forKey:"zoomOut")
check((try? TerminalPreferences.validateShortcuts(missing)) == nil,"partial settings cannot disable an action accidentally")
exit(failures == 0 ? 0 : 1)
