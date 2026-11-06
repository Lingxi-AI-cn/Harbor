import Foundation
var failures = 0
func check(_ ok: Bool,_ name: String) { print("\(ok ? "PASS" : "FAIL"): \(name)"); if !ok { failures += 1 } }
let arguments = CommandLine.arguments
if let index=arguments.firstIndex(of:"--expect-language"),arguments.indices.contains(index+1) {
    check(L10n.activeLanguage.rawValue==arguments[index+1],"process system language resolution: \(L10n.activeLanguage.rawValue)")
    exit(failures == 0 ? 0:1)
}
if arguments.contains("--set-chinese") { L10n.preference = .simplifiedChinese; print("SYNC \(L10n.defaults.synchronize()) VALUE \(L10n.defaults.string(forKey:"interfaceLanguage") ?? "nil")"); exit(0) }
if arguments.contains("--check-persisted") { print("PREFERENCE \(L10n.preference.rawValue) ACTIVE \(L10n.activeLanguage.rawValue)"); check(L10n.preference == .simplifiedChinese && L10n.activeLanguage == .simplifiedChinese,"saved language survives a new process"); exit(failures == 0 ? 0:1) }
if arguments.contains("--reset") {
    L10n.defaults.removeObject(forKey:"interfaceLanguage"); L10n.defaults.synchronize(); exit(0)
}
check(L10n.preference == .system,"unset preference follows system")
check(L10n.resolve(preference:.system,preferredLanguages:["zh-CN"]) == .simplifiedChinese,"Chinese system language")
check(L10n.resolve(preference:.system,preferredLanguages:["zh-Hant-TW"]) == .simplifiedChinese,"Chinese variants use available simplified Chinese")
check(L10n.resolve(preference:.system,preferredLanguages:["en-GB","zh-CN"]) == .english,"English system preference takes precedence")
check(L10n.resolve(preference:.system,preferredLanguages:["fr-FR","zh_CN"]) == .simplifiedChinese,"select first supported preferred language")
check(L10n.resolve(preference:.system,preferredLanguages:["ja-JP"]) == .english,"unsupported system language falls back to English")
check(L10n.resolve(preference:.english,preferredLanguages:["zh-CN"]) == .english,"explicit English overrides system")
check(L10n.resolve(preference:.simplifiedChinese,preferredLanguages:["en-US"]) == .simplifiedChinese,"explicit Chinese overrides system")
let user = "Connect {1} %s 中文"
let text:LocalizedText = "Replay \(7) events in \(user)?"
check(L10n.render(text,language:.english) == "Replay 7 events in Connect {1} %s 中文?","English interpolation preserves user data")
check(L10n.render(text,language:.simplifiedChinese) == "在 Connect {1} %s 中文 中回放 7 个事件？","translation reorders placeholders without interpreting user braces")
check(L10n.text("unknown-key",language:.simplifiedChinese)=="unknown-key","missing key uses source text")
let translated = LocalizationCatalog.chinese.count
L10n.defaults.set("invalid",forKey:"interfaceLanguage")
check(L10n.preference == .system,"invalid stored language safely defaults to system")
L10n.defaults.removeObject(forKey:"interfaceLanguage")
print("RESULT entries=\(translated) failures=\(failures)")
exit(failures == 0 ? 0:1)
