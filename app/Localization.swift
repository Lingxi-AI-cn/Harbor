import Foundation

/// Presentation text only. Never use translated values as protocol/config identifiers.
enum AppLanguage: String, CaseIterable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
}

enum L10n {
    static let defaults = UserDefaults(suiteName:ProcessInfo.processInfo.environment["HARBOR_TEST_PREFERENCES_DOMAIN"] ?? "local.harbor.terminal.preferences")!
    static var preference: AppLanguage {
        get { AppLanguage(rawValue:defaults.string(forKey:"interfaceLanguage") ?? "system") ?? .system }
        set { defaults.set(newValue.rawValue,forKey:"interfaceLanguage") }
    }
    /// Frozen for the process: changing language never interrupts active connections.
    static let activeLanguage: AppLanguage = resolve(
        preference:AppLanguage(rawValue:ProcessInfo.processInfo.environment["HARBOR_LANGUAGE"] ?? "") ?? preference,
        preferredLanguages:Locale.preferredLanguages)
    static func resolve(preference: AppLanguage, preferredLanguages: [String]) -> AppLanguage {
        guard preference == .system else { return preference }
        for language in preferredLanguages {
            let base = language.lowercased().replacingOccurrences(of:"_",with:"-")
            if base == "zh" || base.hasPrefix("zh-") { return .simplifiedChinese }
            if base == "en" || base.hasPrefix("en-") { return .english }
        }
        return .english
    }
    static func configureSystemControls() {
        // Volatile process-only override; never change the user's system language.
        var domain = UserDefaults.standard.volatileDomain(forName:UserDefaults.argumentDomain)
        domain["AppleLanguages"] = [activeLanguage.rawValue]
        UserDefaults.standard.setVolatileDomain(domain,forName:UserDefaults.argumentDomain)
    }
    static func desktopMessage(_ message: String) -> String {
        let prefix = "RDP connection failed (", suffix = "). Check credentials, certificate and server settings."
        if message.hasPrefix(prefix), message.hasSuffix(suffix) {
            let code = String(message.dropFirst(prefix.count).dropLast(suffix.count))
            return L("RDP connection failed (\(code)). Check credentials, certificate and server settings.")
        }
        return text(message)
    }
    static func text(_ key: String, language: AppLanguage = activeLanguage) -> String {
        language == .simplifiedChinese ? (LocalizationCatalog.chinese[key] ?? key) : key
    }
    static func render(_ value: LocalizedText, language: AppLanguage = activeLanguage) -> String {
        let template = text(value.key,language:language)
        // Replace in one pass: a path or user name containing "{1}" stays literal.
        let regex = try! NSRegularExpression(pattern:#"\{([0-9]+)\}"#)
        let source = template as NSString
        var result = "", offset = 0
        for match in regex.matches(in:template,range:NSRange(location:0,length:source.length)) {
            result += source.substring(with:NSRange(location:offset,length:match.range.location-offset))
            let index = Int(source.substring(with:match.range(at:1)))!
            result += value.arguments.indices.contains(index) ? value.arguments[index] : source.substring(with:match.range)
            offset = NSMaxRange(match.range)
        }
        return result + source.substring(from:offset)
    }
}

struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    init(stringLiteral value: String) { key=value; arguments=[] }
    init(stringInterpolation value: StringInterpolation) { key=value.key; arguments=value.arguments }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = "", arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ value: String) { key += value }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing:value))
        }
    }
}
func L(_ text: LocalizedText) -> String { L10n.render(text) }
