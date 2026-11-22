import Foundation

/// The listening agent: tells you when someone says something you would not want to miss, and works out
/// who each voice is ("Barista", "Teacher", "Friend").
///
/// The understanding is not done on the phone. Every two seconds the microphone sound since the last time
/// is sent to a Mac on the same Wi-Fi (`agent_service.py`), together with which voice was talking in each
/// tenth of a second. The Mac keeps a running transcript of the last minute and a half and asks an AI model
/// about the whole conversation, so it knows the setting before it speaks up. It is meant to stay quiet for
/// ordinary chat and only raise the card for things like an order being called or a question to you.
///
/// NOTE: this link is plain HTTP on the local network with no password. Use it on a private network
/// (a phone hotspot), not shared Wi-Fi. If the Mac cannot be reached nothing is shown.
@MainActor
final class Agent: ObservableObject {
    /// The Mac running agent_service.py. Change this to the Mac's address.
    static let host = "your-mac.local:8911"
    static let everySec = 2.0, showSec = 18.0

    struct Alert: Equatable { let who: String; let summary: String; let voice: Int? }
    @Published var alert: Alert?
    /// What the Mac worked out each voice is, from what they say. Empty until it knows.
    @Published var labels: [Int: String] = [:]

    private var talkers: [Int] = []                  // who talked in each tenth of a second since the last send (-1 nobody, -2 several)
    private var sentTo = 0                           // microphone samples already sent
    private var sinceSend = 0.0, shown = 0.0, busy = false, started = false
    private var lastAlertID = 0

    func dismiss() { alert = nil }

    /// Call ten times a second while the screen is up.
    func tick(_ m: Model) {
        guard m.running else {
            talkers = []; started = false; sentTo = 0; lastAlertID = 0
            if !labels.isEmpty { labels = [:] }
            if alert != nil { alert = nil }
            return
        }
        let now = m.bubbles.filter { $0.talking }.map { $0.id }
        talkers.append(now.count == 1 ? now[0] : (now.isEmpty ? -1 : -2))
        if alert != nil { shown += 0.1; if shown > Agent.showSec { alert = nil } }
        sinceSend += 0.1
        guard sinceSend >= Agent.everySec, !busy else { return }
        sinceSend = 0
        let sr = m.audio.sampleRate, end = m.audio.wIdx
        if sentTo > end { sentTo = 0 }                                              // the microphone restarted
        let from = max(sentTo, end - Int(8 * sr))                                   // never more than 8 s at once
        guard end - from >= Int(1.0 * sr) else { return }
        let clip = Agent.to16k(m.audio.read(from: from, to: end), rate: sr)
        let who = talkers.suffix(Int(Double(end - from) / sr * 10)).map(String.init).joined(separator: ",")
        talkers = []
        let fresh = !started
        let selected = [m.selected, m.selectedAlso].compactMap { $0 }
        busy = true
        Task {
            let reply = await Agent.send(clip, fresh: fresh, who: who, selected: selected)
            busy = false
            guard let reply else { return }                                         // the Mac did not answer: send this sound again next time
            started = true; sentTo = end
            if reply.labels != labels { labels = reply.labels }
            if let a = reply.alert, a.id != lastAlertID {
                lastAlertID = a.id
                if m.selected != a.voice && m.selectedAlso != a.voice { alert = Alert(who: a.who, summary: a.summary, voice: a.voice); shown = 0 }
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

    struct Reply { let alert: (id: Int, who: String, summary: String, voice: Int)?; let labels: [Int: String] }

    /// Hand the Mac the newest sound; it answers with what it knows so far. nil = the Mac did not answer.
    nonisolated static func send(_ clip: [Float], fresh: Bool, who: String, selected: [Int]) async -> Reply? {
        var parts = URLComponents(string: "http://\(host)/chunk")
        parts?.queryItems = [URLQueryItem(name: "fresh", value: fresh ? "1" : "0"), URLQueryItem(name: "who_", value: who),
                             URLQueryItem(name: "sel", value: selected.map(String.init).joined(separator: ","))]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        guard let (data, _) = try? await URLSession.shared.upload(for: request, from: wav(clip)),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["labels"] != nil else { return nil }
        var names: [Int: String] = [:]
        for (k, v) in (reply["labels"] as? [String: String]) ?? [:] { if let id = Int(k) { names[id] = String(v.prefix(18)) } }
        var alert: (Int, String, String, Int)? = nil
        if let a = reply["alert"] as? [String: Any], let id = a["id"] as? Int, let voice = a["voice"] as? Int,
           let role = a["role"] as? String, !role.isEmpty {
            alert = (id, role, ((a["summary"] as? String) ?? "").split(separator: " ").prefix(6).joined(separator: " "), voice)
        }
        return Reply(alert: alert.map { (id: $0.0, who: $0.1, summary: $0.2, voice: $0.3) }, labels: names)
    }
}
