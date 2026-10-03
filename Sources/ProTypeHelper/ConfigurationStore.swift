import Foundation
import KeyboardCore

/// The helper's own copy of the configuration, so remapping survives the app
/// quitting, logout, and reboot.
enum ConfigurationStore {
    static let directory = URL(fileURLWithPath: "/Library/Application Support/ProTypeUltra")
    static var url: URL { directory.appendingPathComponent("configuration.json") }

    /// A missing or invalid file means "disabled, automatic device". It is
    /// rewritten the next time the app configures the helper.
    static func load() -> HelperConfiguration {
        guard let data = try? Data(contentsOf: url), data.count <= 4_000_000,
              let configuration = try? JSONDecoder().decode(HelperConfiguration.self, from: data),
              (try? configuration.validate()) != nil else {
            return HelperConfiguration(enabled: false, deviceID: nil, settings: Settings())
        }
        return configuration
    }
    static func save(_ configuration: HelperConfiguration) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
