import Foundation

public struct Key: Codable, Hashable, Sendable, Identifiable {
    public var page: UInt32
    public var usage: UInt32
    public var id: String { "\(page):\(usage)" }
    public init(_ usage: UInt32, page: UInt32 = 7) { self.page = page; self.usage = usage }
    public var label: String { KeyCatalog.labels[self] ?? String(format: "%02X:%02X", page, usage) }
}

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case keys, disabled, text, launch, macro, pointer
}
public struct Binding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var source: Key
    public var alternate = false
    public var kind: ActionKind = .keys
    public var keys: [Key] = []
    public var text = ""
    public var macroID: UUID?
    public var dx = 0
    public var dy = 0
    public var scroll = 0
    public init(source: Key, keys: [Key] = []) { self.source = source; self.keys = keys }
}
public struct MacroStep: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var delayMS: Int = 0
    public var key: Key
    public var down: Bool
    public init(key: Key, down: Bool, delayMS: Int = 0) { self.key = key; self.down = down; self.delayMS = delayMS }
}
public enum MacroMode: String, Codable, CaseIterable, Sendable { case once, counted, whileHeld, toggle }
public struct Macro: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name = "New macro"
    public var mode: MacroMode = .once
    public var repetitions = 1
    public var steps: [MacroStep] = []
    public init() {}
}
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name = "Default"
    public var applicationIDs: [String] = []
    public var layerKey: Key? = nil
    public var bindings: [Binding] = []
    public var macros: [Macro] = []
    public init() {}
    public func validate() throws {
        guard !name.isEmpty, name.count <= 100, bindings.count <= 512, macros.count <= 100,
              applicationIDs.count <= 100, applicationIDs.allSatisfy({ $0.count <= 255 }),
              Set(macros.map(\.id)).count == macros.count,
              Set(bindings.map(\.id)).count == bindings.count else { throw ProfileError.invalid("Profile size or identifiers") }
        if let key = layerKey { try Self.validate(key) }
        var sources = Set<String>()
        for binding in bindings {
            try Self.validate(binding.source)
            guard sources.insert("\(binding.source.id):\(binding.alternate)").inserted else { throw ProfileError.invalid("Duplicate key binding") }
            guard binding.keys.count <= 16, binding.text.count <= 16_384,
                  (-127...127).contains(binding.dx), (-127...127).contains(binding.dy), (-127...127).contains(binding.scroll) else { throw ProfileError.invalid("Action size") }
            try binding.keys.forEach(Self.validate)
            if binding.kind == .macro, !macros.contains(where: { $0.id == binding.macroID }) { throw ProfileError.invalid("Missing macro") }
            if binding.kind == .launch, !(binding.text.hasPrefix("/") && binding.text.hasSuffix(".app")) { throw ProfileError.invalid("Choose an absolute .app path") }
        }
        for macro in macros {
            guard !macro.name.isEmpty, macro.steps.count <= 4096, (1...1000).contains(macro.repetitions),
                  !macro.steps.isEmpty else { throw ProfileError.invalid("Macro must contain steps; repetitions must be 1–1000") }
            var held = Set<Key>()
            for step in macro.steps {
                try Self.validate(step.key)
                guard (0...60_000).contains(step.delayMS) else { throw ProfileError.invalid("Delay must be 0–60000 ms") }
                if step.down { guard held.insert(step.key).inserted else { throw ProfileError.invalid("Duplicate macro key-down") } }
                else { guard held.remove(step.key) != nil else { throw ProfileError.invalid("Macro key-up has no key-down") } }
            }
            guard held.isEmpty else { throw ProfileError.invalid("Macro must release every key") }
        }
    }
    public static func validate(_ key: Key) throws {
        let valid = (key.page == 7 && (4...231).contains(key.usage)) ||
            (key.page == 12 && (1...0x3FF).contains(key.usage)) ||
            (key.page == 9 && (1...32).contains(key.usage)) ||
            (key.page == 1 && (0x81...0x83).contains(key.usage))
        guard valid else { throw ProfileError.invalid("Unsupported HID key \(key.id)") }
    }
}
public enum ProfileError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
/// Backlight behaviour the helper maintains. The keyboard has one dimmable white
/// zone (per-key control is refused by the firmware), so effects beyond the
/// firmware's own are brightness animations driven by the helper.
public struct LightingSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case staticWhite, breathing, reactive, candle }
    public var mode: Mode = .staticWhite
    /// Full brightness, raw 0–255. 0 turns the backlight off.
    public var brightness: UInt8 = 255
    /// Reactive: level while idle, as a fraction of `brightness`.
    public var idleFraction = 0.15
    /// Reactive: seconds to fade from full back to the idle level after the last keypress.
    public var fadeSeconds = 3.0
    /// Candle: how much the flame wanders, 0–1.
    public var flicker = 0.35
    /// False until the user touches lighting in the app; the helper then leaves the
    /// keyboard's own settings alone.
    public var managed = false
    public init() {}
    public func validate() throws {
        guard (0...1).contains(idleFraction), (0.2...30).contains(fadeSeconds), (0...1).contains(flicker) else { throw ProfileError.invalid("Lighting values out of range") }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var version = 1
    public var profiles: [Profile] = [Profile()]
    public var selectedProfile: UUID
    public var automaticProfiles = true
    /// `nil` means the keyboard is chosen automatically.
    public var selectedDevice: String? = nil
    /// Whether the helper should capture and remap the keyboard. Persisted so
    /// the choice survives app restarts; the helper keeps its own copy.
    public var remappingEnabled = false
    public var lighting = LightingSettings()
    public init() { selectedProfile = profiles[0].id }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        selectedProfile = try c.decode(UUID.self, forKey: .selectedProfile)
        automaticProfiles = try c.decodeIfPresent(Bool.self, forKey: .automaticProfiles) ?? true
        selectedDevice = try c.decodeIfPresent(String.self, forKey: .selectedDevice)
        remappingEnabled = try c.decodeIfPresent(Bool.self, forKey: .remappingEnabled) ?? false
        lighting = try c.decodeIfPresent(LightingSettings.self, forKey: .lighting) ?? LightingSettings()
    }
    public func validate() throws {
        guard version == 1, (1...100).contains(profiles.count), Set(profiles.map(\.id)).count == profiles.count,
              profiles.contains(where: { $0.id == selectedProfile }) else { throw ProfileError.invalid("Invalid settings version or selected profile") }
        try profiles.forEach { try $0.validate() }
        try lighting.validate()
    }
    public func activeProfile(applicationID: String?) -> Profile {
        if automaticProfiles, let app = applicationID,
           let matched = profiles.first(where: { $0.applicationIDs.contains(app) }) { return matched }
        return profiles.first(where: { $0.id == selectedProfile }) ?? profiles[0]
    }
}
public enum ProfileStore {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProTypeUltra") }
    public static func load(from url: URL = directory.appendingPathComponent("settings.json")) throws -> Settings {
        if !FileManager.default.fileExists(atPath: url.path) { return Settings() }
        return try decode(Data(contentsOf: url))
    }
    public static func decode(_ data: Data) throws -> Settings {
        guard data.count <= 4_000_000 else { throw ProfileError.invalid("Profile file exceeds 4 MB") }
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        try settings.validate(); return settings
    }
    public static func save(_ settings: Settings, to url: URL = directory.appendingPathComponent("settings.json")) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum KeyCatalog {
    public static let labels: [Key: String] = {
        var result: [Key: String] = [:]
        for (i,c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { result[Key(UInt32(i + 4))] = String(c) }
        for (i,c) in "1234567890".enumerated() { result[Key(UInt32(i + 30))] = String(c) }
        for i in 0..<12 { result[Key(UInt32(i + 58))] = "F\(i + 1)" }
        let extras: [(UInt32,String)] = [(40,"Return"),(41,"Escape"),(42,"Backspace"),(43,"Tab"),(44,"Space"),(45,"-"),(46,"="),(47,"["),(48,"]"),(49,"\\"),(51,";"),(52,"'"),(53,"`"),(54,","),(55,"."),(56,"/"),(57,"Caps Lock"),(70,"Print Screen"),(71,"Scroll Lock"),(72,"Pause"),(73,"Insert"),(74,"Home"),(75,"Page Up"),(76,"Delete"),(77,"End"),(78,"Page Down"),(79,"Right"),(80,"Left"),(81,"Down"),(82,"Up"),(83,"Num Lock"),(84,"Keypad /"),(85,"Keypad *"),(86,"Keypad -"),(87,"Keypad +"),(88,"Keypad Enter"),(98,"Keypad 0"),(99,"Keypad ."),(101,"Menu"),(224,"Left Control"),(225,"Left Shift"),(226,"Left Option"),(227,"Left Command"),(228,"Right Control"),(229,"Right Shift"),(230,"Right Option"),(231,"Right Command")]
        for (code,name) in extras { result[Key(code)] = name }
        for i in 1...9 { result[Key(UInt32(88+i))] = "Keypad \(i)" }
        for (code,name) in [(0xE2,"Mute"),(0xE9,"Volume Up"),(0xEA,"Volume Down"),(0xCD,"Play/Pause"),(0xB5,"Next Track"),(0xB6,"Previous Track")] { result[Key(UInt32(code),page:12)] = name }
        for i in 1...5 { result[Key(UInt32(i),page:9)] = "Mouse \(i)" }
        return result
    }()
    public static var all: [Key] { labels.keys.sorted { ($0.page,$0.usage) < ($1.page,$1.usage) } }
}
