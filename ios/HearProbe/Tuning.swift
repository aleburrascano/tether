import Foundation
import FluidAudio

/// Switches for each improvement, so one test session can compare them. Read by the audio/model threads.
/// Saved between launches.
enum Tuning {
    private static let d = UserDefaults.standard
    private static func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    /// Mute: NVIDIA's tuned Sortformer smoothing (hysteresis 0.641/0.561, 0.23 s early start, gap filling)
    static var smoothing: Bool { get { b("smoothing", true) } set { d.set(newValue, forKey: "smoothing") } }
    /// Clip builder: only keep clip pieces whose voiceprint matches the person
    static var clipCheck: Bool { get { b("clipCheck", true) } set { d.set(newValue, forKey: "clipCheck") } }
    /// Filter: pull out the loudest interrupter first and subtract them (2 filter passes)
    static var subtract: Bool { get { b("subtract2", false) } set { d.set(newValue, forKey: "subtract2") } }
    /// Voiceprint layer over the speaker model's slots: tells similar voices on one slot apart, and
    /// recognises a person who comes back on another slot (People.swift)
    static var personCheck: Bool { get { b("personCheck2", false) } set { d.set(newValue, forKey: "personCheck2") } }
    /// Speaker model: v2.1 (default) or v2 (documented as better when many people talk at once). Needs a restart.
    static var modelV2: Bool { get { b("modelV2", false) } set { d.set(newValue, forKey: "modelV2") } }

    static var sortformerConfig: SortformerConfig { modelV2 ? .balancedV2 : .balancedV2_1 }
    static var modelName: String { modelV2 ? "balancedV2" : "balancedV2_1" }
}

/// CAM++ voiceprints (192 numbers per stretch of audio). Calibrated on the Mac 2026-11-22 with two voices:
/// 1.0 s -> 96.7% correct same/different at threshold 0.40; 1.5 s -> 98.7% at 0.43. Too slow-acting for 80 ms
/// decisions; used to check clips and to measure what is being played.
final class Voiceprint {
    static let shared = Voiceprint()
    static let sameThreshold: Float = 0.40
    private var embedder: CampPlusEmbedder?
    private(set) var status = "not loaded"
    private(set) var lastMs: Double = 0

    func load() async {
        status = "loading voiceprint model..."
        do { embedder = try await CampPlusEmbedder.load(); status = "ready" }
        catch { status = "voiceprint model failed: \(error.localizedDescription)" }
    }

    var ready: Bool { embedder != nil }

    /// 16 kHz audio -> unit-length voiceprint. Blocks the calling (background) thread.
    func embed(_ x: [Float]) -> [Float]? {
        guard let e = embedder, x.count >= 8000 else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var out: [Float]? = nil
        let t0 = CFAbsoluteTimeGetCurrent()
        Task.detached { out = try? await e.embed(audio: x); sem.signal() }
        sem.wait()
        lastMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return out
    }

    static func cos(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    static func mean(_ v: [[Float]]) -> [Float]? {
        guard let first = v.first else { return nil }
        var m = [Float](repeating: 0, count: first.count)
        for e in v { for i in 0..<m.count { m[i] += e[i] } }
        let n = max(sqrt(m.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return m.map { $0 / n }
    }
}

extension Tuning {
    /// Background noise + room echo removal (LocalVQE) on what you hear
    static var denoise: Bool { get { b2("denoise", true) } set { UserDefaults.standard.set(newValue, forKey: "denoise") } }
    /// Lift the upper part of the voice (above ~2 kHz) in what the filter plays: it comes out dull otherwise
    static var brighten: Bool { get { b2("brighten", true) } set { UserDefaults.standard.set(newValue, forKey: "brighten") } }
    /// Raise quiet / far people to a comfortable level automatically
    static var autoLevel: Bool { get { b2("autoLevel", true) } set { UserDefaults.standard.set(newValue, forKey: "autoLevel") } }
    /// Save the whole session's mic audio (16 kHz) so every layer can be re-tested offline on the Mac
    static var recordSession: Bool { get { b2("recordSession", true) } set { UserDefaults.standard.set(newValue, forKey: "recordSession") } }
    private static func b2(_ k: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: k) == nil ? def : UserDefaults.standard.bool(forKey: k) }
}

/// LocalVQE (FluidAudio, Apache-2.0, beta): noise suppression + dereverberation, 16 kHz, streaming 16 ms hops,
/// output aligned with input (one hop of delay). Used on the voice filter's output.
final class Denoiser {
    static let shared = Denoiser()
    private var manager: LocalVqeManager?
    private var stream: LocalVqeStream?
    private(set) var status = "not loaded"
    private(set) var lastMs: Double = 0

    func load() async {
        status = "loading noise remover..."
        do {
            manager = try await LocalVqeManager(config: LocalVqeConfig(variant: .v13, chunk: .realtime16ms))
            status = "ready"
        } catch { status = "noise remover failed: \(error.localizedDescription)" }
    }
    var ready: Bool { manager != nil }

    /// Start a fresh stream (new filtered stream = new denoise stream). Blocking.
    func restart() {
        guard let m = manager else { stream = nil; return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached { self.stream = try? await m.makeStream(); sem.signal() }
        sem.wait()
    }

    /// Push 16 kHz audio, get the cleaned audio that is ready. Blocking; call from a background thread.
    func process(_ x: [Float]) -> [Float]? {
        guard let s = stream, !x.isEmpty else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var out: [Float]? = nil
        let t0 = CFAbsoluteTimeGetCurrent()
        let silence = [Float](repeating: 0, count: x.count)       // no far-end reference: denoise + dereverb only
        Task.detached { out = try? await s.enhance(mic: x, reference: silence); sem.signal() }
        sem.wait()
        lastMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return out
    }
}
