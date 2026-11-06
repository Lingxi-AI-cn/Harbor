import Foundation

struct TerminalMacroEvent: Codable {
    var delay: Double = 0
    var kind: String
    var text: String = ""
    var paste: Bool? = nil
    var key: UInt32 = 0, modifiers: UInt32 = 0, consumed: UInt32 = 0, codepoint: UInt32 = 0
    var action: UInt32 = 0
}
