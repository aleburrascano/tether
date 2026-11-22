import AVFoundation
import os

/// Phone mic in -> delay line -> gate (mute everyone but the selected person) -> AirPods.
///
/// All input goes into one ring buffer at the hardware rate. The output plays it back `delay` seconds later,
/// and the speaker model (on another thread) reads the same ring. Each 80 ms frame of input gets a gate value
/// (1 = let through, 0 = mute) once the model has said who was talking in it; until then the last known
/// decision is used. So a longer delay means more of the audio is decided by the model before you hear it.
final class Audio {
    static let frameSec = 0.08                 // the speaker model's frame
    let ringSize = 1 << 19                     // ~10.9 s at 48 kHz
    let ring: UnsafeMutablePointer<Float>
    private(set) var wIdx = 0                  // samples written (input clock)
    private var rIdx = -1                      // next sample to play (-1 = not started)
    private(set) var sampleRate: Double = 48_000
    private(set) var frameLen = 3840

    // gate per frame (ring of frames), written by the model thread, read by the render thread
    let gateFrames = 1 << 12
    let gate: UnsafeMutablePointer<Float>
    let gateFrame: UnsafeMutablePointer<Int>          // which frame number each slot currently holds
    var lastKnownGate: Float = 1

    /// The mute decision for frame fr if one was made (1 = let through, 0 = muted).
    func gateValue(frame fr: Int) -> Float? { let f = fr & (gateFrames - 1); return gateFrame[f] == fr ? gate[f] : nil }

    /// Model thread: set the gate for frame number `fr`.
    func setGate(frame fr: Int, _ v: Float) {
        let f = fr & (gateFrames - 1)
        gate[f] = v; gateFrame[f] = fr
    }

    // filtered audio (48 kHz, same sample indices as the raw ring), written by the Extractor
    let clean: UnsafeMutablePointer<Float>
    private(set) var cleanStart = 0, cleanW = 0
    private(set) var cleanActive = false
    private(set) var cleanHits = 0, cleanMisses = 0     // while active: played filtered vs fell back to raw

    func beginClean(at start: Int) { cleanStart = start; cleanW = start; cleanHits = 0; cleanMisses = 0; cleanActive = true }
    func endClean() { cleanActive = false }
    func writeClean(_ y: [Float]) {
        for (i, v) in y.enumerated() { clean[(cleanW + i) & (ringSize - 1)] = v }
        cleanW += y.count
    }

    // settings
    var delaySec: Double = 0.3
    var listen = true
    var boostDB: Float = 12 { didSet { boostLin = powf(10, boostDB / 20) } }   // what YOU hear, not the models
    private var boostLin: Float = powf(10, 12 / 20)
    private(set) var outPeak: Float = 0                                          // after boost + limiter
    var gating = false                         // true while a person is selected

    // stats
    private(set) var underruns = 0
    private(set) var gainNow: Float = 1
    private(set) var levelDB: Float = -100
    private(set) var routeText = ""
    private(set) var outputIsSpeaker = false

    let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var source: AVAudioSourceNode?
    private var gain: Float = 1

    // recording (raw mic, for offline analysis)
    private var rec: [Float] = [], recPos = 0, recActive = false
    var onRecordingDone: ((URL?) -> Void)?

    init() {
        ring = .allocate(capacity: ringSize); ring.initialize(repeating: 0, count: ringSize)
        gate = .allocate(capacity: gateFrames); gate.initialize(repeating: 1, count: gateFrames)
        clean = .allocate(capacity: ringSize); clean.initialize(repeating: 0, count: ringSize)
        gateFrame = .allocate(capacity: gateFrames); gateFrame.initialize(repeating: -1, count: gateFrames)
    }

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        // A2DP (music link) for AirPods output keeps the phone's own mic as input
        try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try s.setPreferredSampleRate(48_000)
        try s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
        if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) { try s.setPreferredInput(mic) }

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        sampleRate = inFmt.sampleRate
        frameLen = Int(sampleRate * Audio.frameSec)
        wIdx = 0; rIdx = -1; underruns = 0; cleanActive = false
        for i in 0..<gateFrames { gate[i] = 1; gateFrame[i] = -1 }
        lastKnownGate = 1

        let sink = AVAudioSinkNode { [unowned self] _, frames, abl in self.onInput(abl, Int(frames)); return noErr }
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let source = AVAudioSourceNode(format: outFmt) { [unowned self] _, _, frames, abl in self.render(abl, Int(frames)); return noErr }
        engine.attach(sink); engine.attach(source)
        engine.connect(input, to: sink, format: inFmt)
        engine.connect(source, to: engine.mainMixerNode, format: outFmt)
        self.sink = sink; self.source = source
        try engine.start()

        let ins = s.currentRoute.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        let outs = s.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        refreshRoute()
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refreshRoute()
        }
        routeText = "IN: \(ins.joined(separator: ", "))\nOUT: \(outs.joined(separator: ", "))\n\(Int(sampleRate)) Hz, iOS latency in \(Int(s.inputLatency * 1000)) ms + out \(Int(s.outputLatency * 1000)) ms"
    }

    private var routeObserver: NSObjectProtocol?

    /// Headphones in or out: decides whether sound may play (never through the phone speaker: it would feed back).
    func refreshRoute() {
        let r = AVAudioSession.sharedInstance().currentRoute
        outputIsSpeaker = r.outputs.isEmpty || r.outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
        outputName = r.outputs.first?.portName ?? "none"
    }
    private(set) var outputName = ""

    func stop() {
        if let o = routeObserver { NotificationCenter.default.removeObserver(o); routeObserver = nil }
        engine.stop()
        if let sink { engine.detach(sink) }
        if let source { engine.detach(source) }
        sink = nil; source = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: audio threads
    private func onInput(_ ablPtr: UnsafePointer<AudioBufferList>, _ n: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
        guard let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let step = abl.count == 1 ? Int(abl[0].mNumberChannels) : 1      // interleaved: take channel 0
        var e: Float = 0
        for i in 0..<n {
            let v = p[i * step]
            ring[(wIdx + i) & (ringSize - 1)] = v
            e += v * v
            if recActive {
                if recPos < rec.count { rec[recPos] = v; recPos += 1 }
                if recPos >= rec.count { recActive = false; DispatchQueue.global().async { self.saveRecording() } }
            }
        }
        wIdx += n
        levelDB = 0.9 * levelDB + 0.1 * 10 * log10f(e / Float(max(n, 1)) + 1e-12)
    }

    private func render(_ ablPtr: UnsafeMutablePointer<AudioBufferList>, _ n: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard let out = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let target = Int(delaySec * sampleRate) + Int(0.015 * sampleRate)   // +15 ms so input is always ahead
        let w = wIdx
        if rIdx < 0 || abs((w - rIdx) - target) > Int(0.03 * sampleRate) { rIdx = max(0, w - target) }
        let ramp: Float = 1 / Float(0.008 * sampleRate)                       // 8 ms fades, no clicks
        for i in 0..<n {
            guard rIdx < w else { out[i] = 0; underruns += 1; continue }
            let fr = rIdx / frameLen, f = fr & (gateFrames - 1)
            var g: Float = 1
            if gating { g = gateFrame[f] == fr ? gate[f] : lastKnownGate }
            if !listen { g = 0 }
            gain += max(-ramp, min(ramp, g - gain))
            var v = ring[rIdx & (ringSize - 1)]
            if cleanActive {
                if rIdx >= cleanStart && rIdx < cleanW { v = clean[rIdx & (ringSize - 1)]; cleanHits += 1 } else { cleanMisses += 1 }
            }
            // boost, then a soft limiter: quiet speech gets louder, loud moments are rounded off instead of clipping
            let y = v * gain * boostLin
            let a = abs(y)
            let lim: Float = a < 0.5 ? y : (y > 0 ? 1 : -1) * (0.5 + 0.45 * tanhf((a - 0.5) / 0.45))
            out[i] = lim
            outPeak = max(outPeak * 0.9999, abs(lim))
            rIdx += 1
        }
        gainNow = gain
        for b in 1..<abl.count { abl[b].mData?.copyMemory(from: out, byteCount: n * 4) }
    }

    /// Input samples [from, to) as an array (model thread).
    func read(from: Int, to: Int) -> [Float] {
        var a = [Float](repeating: 0, count: max(0, to - from))
        for i in 0..<a.count { a[i] = ring[(from + i) & (ringSize - 1)] }
        return a
    }

    /// Seconds of audio currently between the mic and the output.
    var bufferedSec: Double { rIdx < 0 ? 0 : Double(wIdx - rIdx) / sampleRate }

    // MARK: recording
    func record(seconds: Double) { rec = .init(repeating: 0, count: Int(sampleRate * seconds)); recPos = 0; recActive = true }

    private func saveRecording() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("rec_\(Audio.stamp()).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                                                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(recPos))!
            b.frameLength = AVAudioFrameCount(recPos)
            rec.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: recPos) }
            try f.write(from: b)
            onRecordingDone?(url)
        } catch { onRecordingDone?(nil) }
    }

    static func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f.string(from: Date()) }
}
