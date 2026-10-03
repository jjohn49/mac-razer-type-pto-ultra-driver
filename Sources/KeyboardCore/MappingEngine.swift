import Foundation

public enum Output: Equatable {
    case key(Key, Bool)
    case pointer(Int, Int, Int)
    case userAction(ActionKind, String)
}

/// Single-threaded state machine. Physical keys and each macro own their output;
/// releasing one owner cannot release a key still held by another owner.
public final class MappingEngine {
    public private(set) var profile: Profile
    public private(set) var physical = Set<Key>()
    private var owners: [String: Set<Key>] = [:]
    private var activeBindings: [Key: Binding] = [:]
    private struct Playback {
        var macro: Macro
        var source: Key
        var owner: String
        var index = 0
        var round = 0
        var due: Double
    }
    private var playbacks: [Playback] = []
    public init(profile: Profile = Profile()) { self.profile = profile }

    public func setProfile(_ value: Profile) -> [Output] {
        let output = reset(); profile = value; return output
    }
    public func reset() -> [Output] {
        let keys = Set(owners.values.flatMap { $0 })
        owners.removeAll(); activeBindings.removeAll(); playbacks.removeAll(); physical.removeAll()
        return ordered(keys, down: false).map { .key($0, false) }
    }
    private func ordered(_ keys: Set<Key>, down: Bool) -> [Key] {
        let ordered = keys.sorted {
            let a = ($0.page == 7 && (224...231).contains($0.usage)) ? 0 : 1
            let b = ($1.page == 7 && (224...231).contains($1.usage)) ? 0 : 1
            return (a,$0.page,$0.usage) < (b,$1.page,$1.usage)
        }
        return down ? ordered : ordered.reversed()
    }
    private func change(_ owner: String, to keys: Set<Key>) -> [Output] {
        let before = Set(owners.values.flatMap { $0 })
        if keys.isEmpty { owners.removeValue(forKey: owner) } else { owners[owner] = keys }
        let after = Set(owners.values.flatMap { $0 })
        return ordered(before.subtracting(after), down: false).map { .key($0, false) } +
            ordered(after.subtracting(before), down: true).map { .key($0, true) }
    }
    public func handle(_ key: Key, down: Bool, now: Double) -> [Output] {
        let owner = "physical:\(key.id)"
        if !down {
            guard physical.remove(key) != nil else { return [] }
            activeBindings.removeValue(forKey: key)
            var result = change(owner, to: [])
            let stopped = playbacks.filter { $0.source == key && $0.macro.mode == .whileHeld }
            playbacks.removeAll { $0.source == key && $0.macro.mode == .whileHeld }
            for playback in stopped { result += change(playback.owner, to: []) }
            return result
        }
        guard physical.insert(key).inserted else { return [] }
        if key == profile.layerKey { return [] }
        let alternate = profile.layerKey.map { physical.contains($0) } ?? false
        let binding = profile.bindings.first { $0.source == key && $0.alternate == alternate } ??
            (alternate ? profile.bindings.first { $0.source == key && !$0.alternate } : nil)
        guard let binding else { return change(owner, to: [key]) }
        activeBindings[key] = binding
        switch binding.kind {
        case .disabled: return []
        case .keys: return change(owner, to: Set(binding.keys))
        case .text, .launch: return [.userAction(binding.kind, binding.text)]
        case .pointer: return [.pointer(binding.dx, binding.dy, binding.scroll)]
        case .macro:
            guard let macro = profile.macros.first(where: { $0.id == binding.macroID }) else { return [] }
            if macro.mode == .toggle {
                let old = playbacks.filter { $0.macro.id == macro.id }
                if !old.isEmpty {
                    playbacks.removeAll { $0.macro.id == macro.id }
                    return old.flatMap { change($0.owner, to: []) }
                }
            }
            guard playbacks.count < 32, !macro.steps.isEmpty else { return [] }
            playbacks.append(Playback(macro: macro, source: key, owner: "macro:\(UUID())", due: now + Double(macro.steps[0].delayMS) / 1000))
            return tick(now: now)
        }
    }
    public func tick(now: Double) -> [Output] {
        var output: [Output] = []
        var remaining: [Playback] = []
        for var playback in playbacks {
            var finished = false
            var budget = 128 // Keep a zero-delay macro from monopolizing the input loop.
            while playback.due <= now && budget > 0 {
                budget -= 1
                let step = playback.macro.steps[playback.index]
                var keys = owners[playback.owner] ?? []
                if step.down { keys.insert(step.key) } else { keys.remove(step.key) }
                output += change(playback.owner, to: keys)
                playback.index += 1
                if playback.index == playback.macro.steps.count {
                    playback.round += 1
                    let repeats: Bool
                    switch playback.macro.mode {
                    case .once: repeats = false
                    case .counted: repeats = playback.round < playback.macro.repetitions
                    case .whileHeld: repeats = physical.contains(playback.source)
                    case .toggle: repeats = true
                    }
                    if !repeats { output += change(playback.owner, to: []); finished = true; break }
                    playback.index = 0
                    playback.due += 0.01 // Minimum gap between repeated sequences.
                }
                playback.due += Double(playback.macro.steps[playback.index].delayMS) / 1000
            }
            if !finished { remaining.append(playback) }
        }
        playbacks = remaining
        return output
    }
}
