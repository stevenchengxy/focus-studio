import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? root.appendingPathComponent("Resources", isDirectory: true)
func catalog(_ language: String, table: String = "Localizable") throws -> [String: String] {
    let url = resources.appendingPathComponent("\(language).lproj/\(table).strings")
    let data = try Data(contentsOf: url)
    guard let strings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
        fatalError("Invalid catalog \(url.path)")
    }
    return strings
}
let english = try catalog("en")
let chinese = try catalog("zh-Hans")
precondition(Set(english.keys) == Set(chinese.keys), "Language catalogs must have identical keys")
precondition(chinese.count > 100, "The complete app, not just the language selector, needs translations")
let placeholders = try NSRegularExpression(pattern: "%[0-9$.*+\\-]*(?:hh|ll|[hlLzjt])?[diuoxXfFeEgGaAcCsSpn@]")
func tokens(_ string: String) -> [String] {
    placeholders.matches(in: string, range: NSRange(string.startIndex..., in: string)).map {
        String(string[Range($0.range, in: string)!])
    }.sorted()
}
for key in english.keys.sorted() {
    precondition(!chinese[key]!.isEmpty, "Empty Chinese translation: \(key)")
    precondition(tokens(english[key]!) == tokens(chinese[key]!), "Format placeholder mismatch: \(key)")
}
for language in ["en", "zh-Hans"] {
    let descriptions = try catalog(language, table: "InfoPlist")
    for key in ["NSScreenCaptureUsageDescription", "NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"] {
        precondition(!(descriptions[key] ?? "").isEmpty, "Missing localized permission description")
    }
}
print("Localization catalogs: PASS (\(english.count) matching keys, format placeholders, permission descriptions)")
