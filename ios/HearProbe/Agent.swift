import Foundation

/// The listening agent: tells you when someone says something you may want to hear.
///
/// The understanding is not done on the phone. Every few seconds the last stretch of microphone sound is
/// sent (the last 5 s, every second) to a Mac on the same Wi-Fi (`agent_service.py`), which turns the speech into text and asks an AI
/// model whether it matters (an order or a name being called, an announcement, someone asking for you).
/// If it does, the screen asks "want to hear them?".
///
/// NOTE: this link is plain HTTP on the local network with no password. Use it on a private network
/// (a phone hotspot), not shared Wi-Fi. If the Mac cannot be reached nothing is shown.
@MainActor
final class Agent: ObservableObject {
    /// The Mac running agent_service.py. Change this to the Mac's address.
    static let host = "your-mac.local:8911"
    static let clipSec = 5.0, everySec = 1.0, showSec = 16.0

    struct Alert: Equatable { let who: String; let summary: String; let voice: Int? }
    @Published var alert: Alert?
    /// What the Mac worked out each voice is, from what they say ("Barista", "Judge", "Friend"). Empty until it knows.
    @Published var labels: [Int: String] = [:]
    private var recent: [[Int]] = []                 // who was talking in each of the last 50 ticks (5 s)

    private var talk: [Int: Int] = [:], lastTalker: Int?
    private var sinceAsk = 0.0, shown = 0.0, busy = false, asked = 0
    private var lastSaid = "", lastSaidAt = Date.distantPast      // so the same sentence, heard again in the next clip, does not ask twice

    func dismiss() { alert = nil; lastSaidAt = Date() }

    /// Call ten times a second while the screen is up.
    func tick(_ m: Model) {
        guard m.running else { talk = [:]; recent = []; if !labels.isEmpty { labels = [:] }; asked = 0; return }
        recent.append(m.bubbles.filter { $0.talking }.map { $0.id }); if recent.count > 50 { recent.removeFirst() }
        for b in m.bubbles where b.talking { talk[b.id, default: 0] += 1; lastTalker = b.id }
        if alert != nil { shown += 0.1; if shown > Agent.showSec { alert = nil } }
        sinceAsk += 0.1
        guard sinceAsk >= Agent.everySec, !busy else { return }
        sinceAsk = 0
        let sr = m.audio.sampleRate, end = m.audio.wIdx, want = Int(Agent.clipSec * sr)
        guard end > Int(3 * sr), m.level > -55 else { talk = [:]; return }          // too little sound to be worth asking about
        let clip = Agent.to16k(m.audio.read(from: max(0, end - want), to: end), rate: sr)
        // whose clip is this? the voice that did most of the talking in it, if it was clearly one person
        var count: [Int: Int] = [:]
        for ids in recent { for id in ids { count[id, default: 0] += 1 } }
        let top = count.max { $0.value < $1.value }
        let total = count.values.reduce(0, +)
        let solo: Int? = top.flatMap { $0.value >= 15 && Double($0.value) >= 0.7 * Double(total) ? $0.key : nil }
        let voice = solo ?? top?.key ?? lastTalker
        // if the voice you are already hearing did a fair share of the talking in this clip, there is nothing to ask
        let mine = m.selected.map { sel in voice == sel || Double(count[sel] ?? 0) >= 0.35 * Double(max(1, total)) } ?? false
        talk = [:]
        busy = true
        let fresh = asked == 0; asked += 1
        Task {
            let (found, names) = await Agent.ask(clip, fresh: fresh, voice: solo)
            busy = false
            if let names, names != labels { labels = names }
            if let found, !mine, !(voice != nil && m.selected == voice) {                  // already listening to them: no need to ask
                let again = found.1 == lastSaid && Date().timeIntervalSince(lastSaidAt) < 20
                if !again, alert == nil { alert = Alert(who: found.0, summary: found.1, voice: voice); shown = 0 }
                lastSaid = found.1; lastSaidAt = Date()
            }
        }
    }

    /// Plain averaging down to 16 kHz (speech-to-text does not need better).
    static func to16k(_ x: [Float], rate: Double) -> [Float] {
        let step = rate / 16_000
        guard step > 1.01 else { return x }
        let n = Int(Double(x.count) / step)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = Int(Double(i) * step), b = min(x.count, max(a + 1, Int(Double(i + 1) * step)))
            var s: Float = 0
            for j in a..<b { s += x[j] }
            out[i] = s / Float(b - a)
        }
        return out
    }

    static func wav(_ x: [Float]) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(x.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(bytes)
        for v in x { put(Int16(max(-1, min(1, v)) * 32767)) }
        return d
    }

    /// What the Mac found: (who, a few words) if it is worth hearing, and its names for the voices so far.
    /// Both nil when the Mac did not answer.
    nonisolated static func ask(_ clip: [Float], fresh: Bool, voice: Int?) async -> ((String, String)?, [Int: String]?) {
        guard let url = URL(string: "http://\(host)/hear?fresh=\(fresh ? 1 : 0)&voice=\(voice ?? -1)") else { return (nil, nil) }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        guard let (data, _) = try? await URLSession.shared.upload(for: request, from: wav(clip)),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        var names: [Int: String] = [:]
        for (k, v) in (reply["labels"] as? [String: String]) ?? [:] { if let id = Int(k) { names[id] = String(v.prefix(18)) } }
        guard reply["alert"] as? Bool == true else { return (nil, names) }
        let who = (reply["role"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let words = ((reply["summary"] as? String) ?? (reply["quote"] as? String) ?? "").split(separator: " ").prefix(6).joined(separator: " ")
        // only a real role is shown ("Barista"); with none, use that voice's own name if it has one, else say nothing
        let name = who.isEmpty ? (voice.flatMap { names[$0] } ?? "") : who
        return (name.isEmpty ? nil : (name, words), names)
    }
}
