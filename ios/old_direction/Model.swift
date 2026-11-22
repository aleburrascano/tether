import Foundation
import SwiftUI

/// A person on the map: a direction where sound keeps coming from.
struct Person: Identifiable {
    let id: Int
    var angle: Float           // -90 left ... +90 right
    var db: Float              // loudness of that direction (dBFS), used as a rough distance
    var lastSeen: Double
    var active: Bool
    var strength: Float        // share of the recent sound energy (0...1)
}

@MainActor
final class Model: ObservableObject {
    @Published var running = false
    @Published var people: [Person] = []
    @Published var selected: Int? = nil
    @Published var onlySelected = true      // when someone is selected: mute everyone else
    @Published var listening = false
    @Published var snap = Engine.Snapshot()
    @Published var route = ""
    @Published var stereo = true
    @Published var error = ""
    @Published var recordText = ""
    @Published var logName = ""
    @Published var ildScale: Float = 8 { didSet { engine.ildScale = ildScale } }
    @Published var sideways = false
    @Published var calibText = "not calibrated"
    @Published var calibrating: String? = nil        // "left" / "right" while measuring
    private var calibSamples: [Float] = []
    private var calibLeft: Float? = nil, calibRight: Float? = nil

    let engine = Engine()
    private var timer: Timer?
    private var nextId = 1
    private var candidates: [(angle: Float, hits: Int, last: Double)] = []
    private var log: FileHandle?
    private var t0 = Date()
    private var tick = 0

    // MARK: - start / stop
    func toggle() { running ? stop() : start() }

    func start() {
        do {
            engine.orientation = sideways ? .landscapeLeft : .portrait
            try engine.start()
            running = true; error = ""; route = engine.routeText; stereo = engine.channels >= 2
            people = []; selected = nil; candidates = []; nextId = 1
            applyAudioSettings()
            openLog()
            event("start", ["route": route])
            engine.onRecordingDone = { [weak self] url in
                Task { @MainActor in
                    self?.recordText = url.map { "saved \($0.lastPathComponent)" } ?? "save failed"
                    self?.event("recording_saved", ["file": url?.lastPathComponent ?? "failed"])
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        } catch let e {
            error = "Could not start: \(e.localizedDescription)"
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        engine.stop()
        event("stop", [:])
        try? log?.close(); log = nil
        running = false
    }

    // MARK: - interaction
    func tap(_ p: Person) {
        selected = (selected == p.id) ? nil : p.id
        applyAudioSettings()
        event("select", ["person": selected ?? -1, "angle": p.angle])
    }

    func setListening(_ on: Bool) { listening = on; applyAudioSettings(); event("listen", ["on": on]) }
    func setOnlySelected(_ on: Bool) { onlySelected = on; applyAudioSettings(); event("only_selected", ["on": on]) }

    private func applyAudioSettings() {
        engine.listen = listening
        let sel = people.first { $0.id == selected }
        engine.selectedAngle = sel?.angle ?? .nan
        engine.gateOn = onlySelected && sel != nil
    }

    func setSideways(_ on: Bool) {
        sideways = on; calibLeft = nil; calibRight = nil
        engine.ildOffset = 0; ildScale = 8; calibText = "not calibrated"
        event("orientation", ["sideways": on])
        if running { stop(); start() }
    }

    /// Have the person talk from one side for ~4 s of speech; we take the median right-vs-left difference.
    func calibrate(_ side: String) { calibrating = side; calibSamples = []; calibText = "measuring \(side)... keep talking" }

    private func calibStep(_ s: Engine.Snapshot) {
        guard let side = calibrating, s.speech else { return }
        calibSamples.append(s.ildNow)
        if calibSamples.count < 80 { return }                 // 80 speech ticks at 20/s = 4 s of speech
        let med = calibSamples.sorted()[calibSamples.count / 2]
        if side == "left" { calibLeft = med } else { calibRight = med }
        calibrating = nil
        if let l = calibLeft, let r = calibRight {
            let sep = r - l
            engine.ildOffset = (l + r) / 2
            ildScale = abs(sep) < 0.5 ? (sep < 0 ? -0.5 : 0.5) : sep / 2
            calibText = String(format: "left %+.1f dB, right %+.1f dB -> left/right difference %.1f dB %@", l, r, abs(sep),
                               abs(sep) < 2 ? "(TOO SMALL: this phone position can't tell direction reliably)" : abs(sep) < 4 ? "(weak but usable)" : "(good)")
        } else {
            calibText = String(format: "%@ = %+.1f dB. Now do the other side.", side, med)
        }
        event("calibration", ["side": side, "median_ild": med, "offset": engine.ildOffset, "scale": ildScale, "text": calibText])
    }

    func measureDelay() { engine.measureDelay(); event("delay_test", [:]) }
    func record() { engine.record(seconds: 20); recordText = "recording 20 s..."; event("record_start", [:]) }

    // MARK: - tracking (20 times a second)
    private func update() {
        let s = engine.snapshot()
        snap = s
        calibStep(s)
        let now = Date().timeIntervalSince(t0)
        let total = max(s.hist.reduce(0, +), 1e-15)
        let h = s.hist.map { $0 / total }

        // peaks of the direction histogram = directions sound keeps coming from
        var peaks: [(angle: Float, share: Float)] = []
        if s.hist.reduce(0, +) > 1e-9 {
            for b in 0..<Engine.nBins {
                let l = b > 0 ? h[b - 1] : 0, r = b < Engine.nBins - 1 ? h[b + 1] : 0
                if h[b] >= l && h[b] > r && h[b] > 0.12 {
                    // centre of mass of the peak and its neighbours
                    var w: Float = 0, a: Float = 0
                    for j in max(0, b - 2)...min(Engine.nBins - 1, b + 2) { w += h[j]; a += h[j] * Engine.angle(ofBin: j) }
                    peaks.append((a / w, w))
                }
            }
        }

        // match peaks to people (within 20 degrees); a new direction must persist ~0.5 s before it becomes a person
        let inst = s.inst
        var seen = Set<Int>()
        for pk in peaks {
            if let i = people.indices.filter({ !seen.contains(people[$0].id) && abs(people[$0].angle - pk.angle) < 20 })
                .min(by: { abs(people[$0].angle - pk.angle) < abs(people[$1].angle - pk.angle) }) {
                people[i].angle = 0.9 * people[i].angle + 0.1 * pk.angle
                people[i].strength = pk.share
                // "active" = this frame has energy near this person's direction
                var near: Float = 0
                for b in 0..<Engine.nBins where abs(Engine.angle(ofBin: b) - people[i].angle) <= 15 { near += inst[b] }
                people[i].active = s.speech && near > 0.35
                if people[i].active {
                    people[i].lastSeen = now
                    people[i].db = 0.8 * people[i].db + 0.2 * (s.frameDB + 10 * log10f(max(near, 0.01)))
                }
                seen.insert(people[i].id)
            } else if let c = candidates.firstIndex(where: { abs($0.angle - pk.angle) < 15 }) {
                candidates[c].hits += 1; candidates[c].last = now; candidates[c].angle = 0.8 * candidates[c].angle + 0.2 * pk.angle
                if candidates[c].hits >= 20 && people.count < 6 {
                    people.append(Person(id: nextId, angle: candidates[c].angle, db: s.frameDB, lastSeen: now, active: true, strength: pk.share))
                    event("person_new", ["id": nextId, "angle": candidates[c].angle])
                    nextId += 1
                    candidates.remove(at: c)
                }
            } else {
                candidates.append((pk.angle, 1, now))
            }
        }
        for i in people.indices where !seen.contains(people[i].id) { people[i].active = false }
        candidates.removeAll { now - $0.last > 1.0 }          // a candidate must keep showing up
        // forget people not heard for 30 s (but never the selected one)
        let before = people.count
        people.removeAll { now - $0.lastSeen > 30 && $0.id != selected }
        if people.count != before { event("person_gone", [:]) }
        // merge people that drifted onto the same direction (keep the selected / older one)
        var merged = true
        while merged {
            merged = false
            outer: for i in people.indices { for j in people.indices where j > i && abs(people[i].angle - people[j].angle) < 15 {
                let drop = people[j].id == selected ? i : j
                event("person_merged", ["id": people[drop].id])
                people.remove(at: drop); merged = true; break outer
            } }
        }
        applyAudioSettings()

        tick += 1
        if tick % 2 == 0 { writeFrame(now, s) }
    }

    // MARK: - debug log (Documents/debug_*.jsonl, one line per 100 ms)
    private func openLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("debug_\(Engine.stamp()).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        log = try? FileHandle(forWritingTo: url)
        logName = url.lastPathComponent
        t0 = Date()
    }

    private func writeFrame(_ t: Double, _ s: Engine.Snapshot) {
        let r: (Float) -> Double = { ($0.isFinite ? Double(($0 * 100).rounded() / 100) : -999) }
        let line: [String: Any] = [
            "t": (t * 100).rounded() / 100, "type": "frame",
            "L": r(s.levelL), "R": r(s.levelR), "ild": r(s.ild), "lag_ms": r(s.lagMs),
            "db": r(s.frameDB), "noise": r(s.noiseDB), "speech": s.speech,
            "hist": s.hist.map { r($0 / max(s.hist.reduce(0, +), 1e-15)) }, "inst": s.inst.map { r($0) },
            "people": people.map { ["id": $0.id, "angle": r($0.angle), "db": r($0.db), "active": $0.active] },
            "selected": selected ?? -1, "gate": r(s.gate), "sel_frac": r(s.selectedFrac),
            "listen": listening, "only_selected": onlySelected,
            "buffered_ms": r(s.bufferedMs), "underruns": s.underruns, "delay_ms": r(s.delayMs), "ild_scale": r(ildScale), "ild_offset": r(engine.ildOffset), "ild_now": r(s.ildNow), "sideways": sideways, "calibrating": calibrating ?? ""]
        write(line)
    }

    func event(_ name: String, _ data: [String: Any]) {
        var d = data; d["type"] = name; d["t"] = (Date().timeIntervalSince(t0) * 100).rounded() / 100
        write(d)
    }

    private func write(_ d: [String: Any]) {
        guard let log, JSONSerialization.isValidJSONObject(d), let j = try? JSONSerialization.data(withJSONObject: d) else { return }
        log.write(j); log.write("\n".data(using: .utf8)!)
    }
}
