import Foundation
import SwiftUI

@MainActor
final class Model: ObservableObject {
    /// One voice on screen. Without the voiceprint layer id == slot (speaker-model slot 0...3); with it, id is the
    /// person and slot is where they were last heard.
    struct Bubble: Identifiable { let id: Int; var slot: Int; var seconds: Double; var talking: Bool }

    @Published var running = false
    @Published var modelStatus = "not loaded"
    @Published var modelReady = false
    @Published var bubbles: [Bubble] = []
    @Published var selected: Int? = nil
    /// A second voice picked as well (heard together with `selected`). Only ever set while `selected` is.
    @Published var selectedAlso: Int? = nil
    @Published var alsoActive = false
    @Published var listening = true
    @Published var delay: Double = 0.3
    @Published var boost: Double = 12
    @Published var threshold: Double = 0.5
    @Published var route = ""
    @Published var speakerWarning = false
    @Published var error = ""
    @Published var recordText = ""
    @Published var logName = ""
    // debug numbers
    @Published var latest: [Float] = [0, 0, 0, 0]
    @Published var latestFinal = false
    @Published var recent: [[Float]] = []
    @Published var procMs: Double = 0
    @Published var modelLag: Double = 0
    @Published var gainNow: Float = 1
    @Published var buffered: Double = 0
    @Published var underruns = 0
    @Published var level: Float = -100


    @Published var spatialText = ""
    @Published var dirStatus = ""
    @Published var dirBusy = false

    func runSpatialCheck() { spatialText = DirectionTest.spatialCheck() }

    func recordDirection(_ label: String, sideways: Bool) {
        guard !dirBusy else { return }
        if running { stop() }
        dirBusy = true; dirStatus = "recording 10 s - \(label), keep talking..."
        Task.detached {
            let r = DirectionTest.recordStereo(label: label, sideways: sideways)
            await MainActor.run { self.dirStatus = r; self.dirBusy = false }
        }
    }

    func rotationTest(sideways: Bool) {
        guard !dirBusy else { return }
        if running { stop() }                      // the test needs the mic on its own
        dirBusy = true; dirStatus = "recording 35 s - spin the phone slowly, one full turn..."
        Task.detached {
            let r = DirectionTest.rotationTest(sideways: sideways)
            await MainActor.run { self.dirStatus = r; self.dirBusy = false }
        }
    }

    static let minBubbleSec = 0.8          // a voice needs this much speech before it gets a bubble

    let audio = Audio()
    lazy var voices = Voices(audio: audio)
    lazy var extractor = Extractor(audio: audio, voices: voices)
    let people = People()
    @Published var personCheck = Tuning.personCheck
    @Published var personText = ""
    private var selectedSlot: Int? = nil
    private var routeTick = 0
    @Published var brighten = Tuning.brighten
    func setBrighten(_ on: Bool) { brighten = on; Tuning.brighten = on; event("setting", ["brighten": on]) }
    func setPersonCheck(_ on: Bool) { personCheck = on; Tuning.personCheck = on; event("setting", ["person_check": on]) }
    /// The voiceprint layer decides who is on screen (needs its model loaded).
    private var byPerson: Bool { personCheck && Voiceprint.shared.ready }
    let filterOn = true                      // the voice filter is always on
    @Published var clipScore: Double = 0
    @Published var quality: Double = -1
    @Published var subtracting: Int? = nil
    @Published var filterLoad: Double = 0
    @Published var markText = ""
    @Published var smoothing = Tuning.smoothing
    @Published var clipCheck = Tuning.clipCheck
    @Published var subtract = Tuning.subtract
    @Published var modelV2 = Tuning.modelV2
    @Published var denoise = Tuning.denoise
    @Published var autoLevel = Tuning.autoLevel
    @Published var recordSession = Tuning.recordSession
    @Published var autoGainDB: Double = 0
    func setDenoise(_ on: Bool) { denoise = on; Tuning.denoise = on; event("setting", ["denoise": on]) }
    func setAutoLevel(_ on: Bool) { autoLevel = on; Tuning.autoLevel = on; event("setting", ["auto_level": on]) }
    func setRecordSession(_ on: Bool) { recordSession = on; Tuning.recordSession = on; event("setting", ["record_session": on]) }
    func setSmoothing(_ on: Bool) { smoothing = on; Tuning.smoothing = on; event("setting", ["smoothing": on]) }
    func setClipCheck(_ on: Bool) { clipCheck = on; Tuning.clipCheck = on; event("setting", ["clip_check": on]) }
    func setSubtract(_ on: Bool) { subtract = on; Tuning.subtract = on; event("setting", ["subtract": on]) }
    func setModelV2(_ on: Bool) { modelV2 = on; Tuning.modelV2 = on; event("setting", ["model_v2": on]) }

    /// "Something sounded wrong just now": save the last 10 s of mic + filter output, and the moment, for analysis.
    func mark() {
        guard running else { return }
        let stamp = Audio.stamp()
        event("mark", ["stamp": stamp, "selected": selected ?? -1])
        markText = "marked"
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let urls = self.extractor.saveRecent(seconds: 10, stamp: stamp, tag: "mark")
            Task { @MainActor in self.event("mark_saved", ["files": urls.map { $0.lastPathComponent }]); self.markText = "" }
        }
    }
    @Published var filterActive = false
    @Published var soloSec: Double = 0
    @Published var filterMs: Double = 0
    @Published var filterCoverage: Double = 0
    @Published var filterRefreshes = 0
    private var timer: Timer?
    private var log: FileHandle?
    private var t0 = Date()

    func loadModel() {
        if ProcessInfo.processInfo.arguments.contains("-uiDemo") {     // screenshot mode only: fake people, no audio
            running = true; modelReady = true; selected = 1; filterActive = true
            bubbles = [Bubble(id: 0, slot: 0, seconds: 20, talking: false), Bubble(id: 1, slot: 1, seconds: 30, talking: true),
                       Bubble(id: 2, slot: 2, seconds: 12, talking: false), Bubble(id: 3, slot: 3, seconds: 8, talking: true)]
            return
        }
        guard !modelReady else { return }
        modelStatus = "downloading speaker model (first time only)..."
        Task.detached { await Voiceprint.shared.load() }
        Task.detached { await Denoiser.shared.load() }
        Task {
            await voices.load()
            modelStatus = voices.status
            modelReady = voices.ready
        }
    }

    func toggle() { running ? stop() : start() }

    func start() {
        guard modelReady else { error = "Speaker model not ready yet"; return }
        do {
            audio.delaySec = delay
            audio.boostDB = Float(boost)
            try audio.start()
            route = audio.routeText
            speakerWarning = audio.outputIsSpeaker
            selected = nil; selectedSlot = nil; bubbles = []; nextMetricFrame = 0
            selectedAlso = nil; alsoActive = false; extractor.extraSlot = nil; voices.selectAlso(nil)
            applyListen()
            voices.blocked = false
            voices.select(nil)
            voices.threshold = Float(threshold)
            voices.start()
            extractor.enabled = filterOn
            extractor.wantedSlot = nil
            extractor.framesFilter = nil
            extractor.start()
            people.start(voices: voices, extractor: extractor)
            openLog()
            event("start", ["route": route, "delay": delay, "model": Tuning.modelName, "smoothing": Tuning.smoothing,
                            "person_check": Tuning.personCheck, "clip_check": Tuning.clipCheck, "subtract": Tuning.subtract, "voiceprint": Voiceprint.shared.status,
                            "denoise": Tuning.denoise, "brighten": Tuning.brighten, "denoiser": Denoiser.shared.status, "auto_level": Tuning.autoLevel,
                            "session_file": extractor.sessionName])
            audio.onRecordingDone = { [weak self] url in
                Task { @MainActor in
                    self?.recordText = url.map { "saved \($0.lastPathComponent)" } ?? "save failed"
                    self?.event("recording_saved", ["file": url?.lastPathComponent ?? "failed"])
                }
            }
            running = true; error = ""
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        } catch let e { error = "Could not start: \(e.localizedDescription)" }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        people.stop(); extractor.stop(); voices.stop(); audio.stop()
        event("stop", [:]); try? log?.close(); log = nil
        running = false
    }

    /// How many seconds of this voice talking alone the app has heard lately. The voice filter needs
    /// `Extractor.minSoloSec` of it before it can pick that person out, so the screen uses this to show
    /// whether a voice is ready to be picked. (Read only: nothing in the audio path depends on it.)
    func soloSeconds(_ b: Bubble) -> Double { Double(voices.soloFrames(slot: b.slot).count) * Audio.frameSec }

    /// Tap a voice. Nobody picked: it becomes the one you hear. One picked: a different voice is added as a second
    /// (two at most; a third replaces the second). Tap a picked voice again to drop it.
    func tap(_ b: Bubble) {
        if let first = selected, first != b.id {                 // add / drop / swap the second voice
            selectedAlso = (selectedAlso == b.id) ? nil : b.id
            let slot = selectedAlso == nil ? nil : b.slot
            extractor.extraSlot = slot; voices.selectAlso(slot)
            event("select_also", ["slot": slot ?? -1])
            return
        }
        if selected == b.id, let also = selectedAlso, let other = bubbles.first(where: { $0.id == also }) {
            // dropping the first while a second is picked: the second becomes the one you hear
            selectedAlso = nil; extractor.extraSlot = nil; voices.selectAlso(nil)
            selected = other.id; selectedSlot = other.slot
            voices.blocked = false; extractor.framesFilter = nil
            voices.select(selectedSlot); extractor.wantedSlot = selectedSlot
            applyListen(); event("select", ["slot": other.slot, "person": -1])
            return
        }
        selected = (selected == b.id) ? nil : b.id
        selectedSlot = selected == nil ? nil : b.slot
        voices.blocked = false
        extractor.framesFilter = nil
        voices.select(selectedSlot)
        extractor.wantedSlot = selectedSlot
        applyListen()
        event("select", ["slot": selectedSlot ?? -1, "person": byPerson ? (selected ?? -1) : -1])
    }

    /// Sound is played only while a voice is picked: with nobody picked the headphones stay silent
    /// (and never without headphones, which would feed back).
    private func applyListen() { audio.listen = listening && !speakerWarning && selected != nil }
    func setListening(_ on: Bool) { listening = on; applyListen(); event("listen", ["on": on]) }
    func setBoost(_ d: Double) { boost = d; audio.boostDB = Float(d); event("boost", ["db": d]) }
    func setDelay(_ d: Double) { delay = d; audio.delaySec = d; event("delay", ["sec": d]) }
    func record() {
        audio.record(seconds: 20); recordText = "recording 20 s..."; event("record_start", [:])
        let stamp = Audio.stamp()
        DispatchQueue.global().asyncAfter(deadline: .now() + 20.3) { [weak self] in
            guard let self else { return }
            let urls = self.extractor.saveRecent(seconds: 20, stamp: stamp)
            Task { @MainActor in self.event("filter_recording", ["files": urls.map { $0.lastPathComponent }]) }
        }
    }

    private func update() {
        let s = voices.snapshot()
        var b: [Bubble] = []
        if byPerson {
            // one voice per person the voiceprint layer knows; lit while their slot talks and is theirs
            for p in people.list() {
                b.append(Bubble(id: p.id, slot: p.slot, seconds: s.slots[p.slot].speechSec, talking: p.mine && s.slots[p.slot].talking))
            }
            if let sel = selected, let me = b.first(where: { $0.id == sel }) {
                if me.slot != selectedSlot {                    // our person moved to another slot: follow them
                    selectedSlot = me.slot; voices.select(me.slot); extractor.wantedSlot = me.slot
                    event("select_follow", ["slot": me.slot, "person": sel])
                }
            }
            personText = people.text
            for e in people.drainEvents() { write(e.merging(["t": (Date().timeIntervalSince(t0) * 1000).rounded() / 1000]) { a, _ in a }) }
        } else {
            for (i, sl) in s.slots.enumerated() where sl.speechSec >= Model.minBubbleSec || i == selected {
                b.append(Bubble(id: i, slot: i, seconds: sl.speechSec, talking: sl.talking))
            }
        }
        bubbles = b
        latest = s.latest; latestFinal = s.latestIsFinal; recent = s.recent
        routeTick += 1
        if routeTick % 10 == 0 { audio.refreshRoute() }       // ask every second: a missed system notice must not leave the sound off
        if speakerWarning != audio.outputIsSpeaker {          // headphones connected / removed mid-session
            speakerWarning = audio.outputIsSpeaker
            applyListen()
            event("route", ["headphones": !speakerWarning, "output": audio.outputName])
        }
        for e in extractor.drainEvents() { write(e.merging(["t": (Date().timeIntervalSince(t0) * 1000).rounded() / 1000]) { a, _ in a }) }
        clipScore = Double(extractor.clipScore); quality = Double(extractor.quality)
        subtracting = extractor.subtracting; filterLoad = extractor.load; autoGainDB = Double(extractor.autoGainDB)
        alsoActive = extractor.adding != nil && extractor.adding == extractor.extraSlot
        filterActive = extractor.active; soloSec = extractor.soloSec; filterMs = extractor.ms; filterRefreshes = extractor.refreshes
        let tot = audio.cleanHits + audio.cleanMisses
        filterCoverage = tot > 0 ? Double(audio.cleanHits) / Double(tot) : 0
        procMs = voices.procMs; modelLag = voices.modelLagSec
        gainNow = audio.gainNow; buffered = audio.bufferedSec; underruns = audio.underruns; level = audio.levelDB
        writeFrame(s.slots)
        writeMetrics()
    }

    // MARK: per-80 ms metrics (type "f80"): who the model says talked (confident answer), mic level,
    // filter in/out level, whether it was muted, who was selected. Enough to work out per-person levels,
    // how much of the selected person the filter keeps, and how much of others leaks through.
    private var nextMetricFrame = 0
    private func writeMetrics() {
        let lastFinal = voices.latestFinal
        let lastOut = extractor.outReady16 / 1280 - 1
        let upTo = min(lastFinal, lastOut)
        guard upTo >= nextMetricFrame else { return }
        let r: (Double) -> Double = { $0.isFinite ? ($0 * 10).rounded() / 10 : -999 }
        for f in max(nextMetricFrame, upTo - 200)...upTo {
            guard let p = voices.finalPred(f), let lv = extractor.levels(frame: f) else { continue }
            var d: [String: Any] = ["type": "f80", "f": f, "p": p.map { ($0 * 100).rounded() / 100 },
                                    "in": r(lv.inDB), "sel": selectedSlot ?? -1, "boost": boost]
            if let o = lv.outDB { d["out"] = r(o) }
            if let g = audio.gateValue(frame: f) { d["gate"] = Double(g) }
            write(d)
        }
        nextMetricFrame = upTo + 1
    }

    // MARK: debug log: Documents/debug_*.jsonl, one line per 100 ms
    private func openLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("debug_\(Audio.stamp()).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        log = try? FileHandle(forWritingTo: url)
        logName = url.lastPathComponent
        t0 = Date()
    }

    private func writeFrame(_ slots: [Voices.Slot]) {
        let r: (Double) -> Double = { $0.isFinite ? ($0 * 1000).rounded() / 1000 : -999 }
        write(["type": "frame", "t": r(Date().timeIntervalSince(t0)),
               "p": latest.map { r(Double($0)) }, "p_final": latestFinal,
               "speech_sec": slots.map { r($0.speechSec) }, "talking": slots.map { $0.talking },
               "bubbles": bubbles.map { $0.id }, "selected": selectedSlot ?? -1, "person": byPerson ? (selected ?? -1) : -1, "slot_people": people.slotsNow,
               "gain": r(Double(gainNow)), "listen": listening, "delay": delay, "boost": boost, "out_peak": r(Double(audio.outPeak)), "threshold": threshold,
               "buffered": r(buffered), "underruns": underruns, "level_db": r(Double(level)),
               "filter_on": filterOn, "filter_active": filterActive, "solo_sec": r(soloSec), "filter_ms": r(filterMs),
               "filter_skips": extractor.skips, "filter_coverage": r(filterCoverage), "filter_load": r(filterLoad), "auto_gain_db": r(autoGainDB), "denoise_ms": r(Denoiser.shared.lastMs), "subtracting": subtracting ?? -1, "filter_refreshes": filterRefreshes,
               "proc_ms": r(procMs), "model_lag": r(modelLag), "errors": voices.errors])
    }

    func event(_ name: String, _ data: [String: Any]) {
        var d = data; d["type"] = name; d["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
        write(d)
    }

    private func write(_ d: [String: Any]) {
        guard let log, JSONSerialization.isValidJSONObject(d), let j = try? JSONSerialization.data(withJSONObject: d) else { return }
        log.write(j); log.write("\n".data(using: .utf8)!)
    }
}
