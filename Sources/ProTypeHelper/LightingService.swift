import Foundation
import KeyboardCore
import KeyboardHID

/// Owns the keyboard's control interface inside the helper. Applies the user's
/// backlight choice at boot and on reconnect, animates the single white zone for
/// the software effects, and proxies the app's own reads and writes so nothing
/// interleaves on the wire. Everything runs on one serial queue.
final class LightingService {
    private let queue = DispatchQueue(label: "local.protypeultra.lighting", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var transport: HIDTransport?
    private var session: RazerSession?
    private var deviceID: String?
    private var settings = LightingSettings()
    private var applied = false
    private var lastOpenAttempt = -10.0
    private var lastWritten = -1
    private var lastWriteTime = -10.0
    private var lastActivity = -1000.0
    private var lastTick = 0.0
    // Animation state, all in perceptual 0…1 space.
    private var level = 1.0
    private var flameWalk = 0.0
    private var flameTarget = 0.0
    private var nextFlameChange = 0.0
    private var phases = (0..<3).map { _ in Double.random(in: 0..<(2 * .pi)) }

    private static let frameInterval = 1.0 / 30
    /// The LED driver is roughly linear in power; eyes are not. Fading in this space
    /// keeps the steps even from dim to bright.
    private static let gamma = 2.2

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var animated: Bool { settings.managed && (settings.mode == .reactive || settings.mode == .candle) }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume(); self.timer = timer
    }

    // MARK: Inputs from the rest of the helper (any thread)

    func setDevice(_ id: String?, wireless: Bool) {
        queue.async { [self] in
            guard id != deviceID else { return }
            deviceID = id; transport = nil; session = nil; applied = false; lastWritten = -1
        }
    }
    func update(_ next: LightingSettings) {
        queue.async { [self] in
            guard next != settings else { return }
            settings = next; applied = false
        }
    }
    /// Only the moment of a keypress is recorded, never which key.
    func noteActivity() { queue.async { [self] in lastActivity = now } }
    var available: Bool { queue.sync { transport != nil || deviceID != nil } }

    /// The app's and CLI's own hardware traffic, serialized with the animation.
    func exchange(_ packet: [UInt8]) throws -> [UInt8] {
        try queue.sync {
            guard let transport = try openIfNeeded() else { throw RazerError.unavailable("No configuration interface. Connect the USB cable or receiver.") }
            do { return try transport.exchange(packet) }
            catch { dropSession(error); throw error }
        }
    }

    // MARK: Queue-only

    private func openIfNeeded() throws -> HIDTransport? {
        if let transport { return transport }
        guard let deviceID, now - lastOpenAttempt > 2 else { return nil }
        lastOpenAttempt = now
        do {
            let t = try HIDTransport(deviceID: deviceID)
            transport = t; session = RazerSession(transport: t, wireless: t.wireless); applied = false; lastWritten = -1
            return t
        } catch RazerError.unavailable { return nil }
    }
    private func dropSession(_ error: Error) {
        if case RazerError.unavailable = error { transport = nil; session = nil; applied = false }
    }

    private func tick() {
        let now = now
        let dt = lastTick == 0 ? Self.frameInterval : min(0.25, now - lastTick)
        lastTick = now
        guard settings.managed else { return }
        guard (try? openIfNeeded()) != nil, let session else { return }
        if !applied { applyMode(session); return }
        guard animated else { return }
        switch settings.mode {
        case .reactive:
            // Target: full for a moment after a keypress, then the idle level. The level
            // chases the target exponentially: a quick rise, then a long settle with no
            // corner at the end.
            let target = now - lastActivity < 0.12 ? 1.0 : settings.idleFraction
            let tau = target > level ? 0.06 : max(0.2, settings.fadeSeconds / 3)
            level += (target - level) * (1 - exp(-dt / tau))
        case .candle:
            // A flame: three slow waves plus a slowly wandering target. No per-frame noise.
            let t = now
            let waves = 0.5 * sin(2 * .pi * 0.37 * t + phases[0]) + 0.3 * sin(2 * .pi * 0.83 * t + phases[1]) + 0.2 * sin(2 * .pi * 1.31 * t + phases[2])
            if t >= nextFlameChange { flameTarget = Double.random(in: -1...1); nextFlameChange = t + Double.random(in: 1.2...3.0) }
            flameWalk += (flameTarget - flameWalk) * (1 - exp(-dt / 0.9))
            let flame = 0.55 * waves + 0.45 * flameWalk          // −1 … 1
            let depth = settings.flicker * 0.6                    // how far below full it dips
            level = 1 - depth * (0.5 + 0.5 * flame)
        default:
            return
        }
        write(level, session, now: now)
    }

    private func applyMode(_ session: RazerSession) {
        do {
            switch settings.mode {
            case .staticWhite, .reactive, .candle: _ = try session.perform(.effect(.staticWhite))
            case .breathing: _ = try session.perform(.effect(.breathing))
            }
            _ = try session.perform(.brightness(settings.brightness))
            lastWritten = Int(settings.brightness); lastWriteTime = now
            level = settings.mode == .reactive ? settings.idleFraction : 1
            flameWalk = 0; flameTarget = 0; nextFlameChange = 0
            applied = true
        } catch { dropSession(error) }
    }

    private func write(_ fraction: Double, _ session: RazerSession, now: Double) {
        let clamped = min(1, max(0, fraction))
        let raw = Int((Double(settings.brightness) * pow(clamped, Self.gamma)).rounded())
        guard raw != lastWritten, now - lastWriteTime >= Self.frameInterval * 0.9 else { return }
        do { try session.send(.brightness(UInt8(raw))); lastWritten = raw; lastWriteTime = now }
        catch { dropSession(error) }
    }
}
