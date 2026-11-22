import AVFoundation
import Accelerate
import os

/// Audio engine: phone's stereo mics in -> direction analysis -> (optional gate) -> AirPods out.
///
/// Every 1024 samples (~21 ms at 48 kHz) it analyses the last 2048 samples of both channels: for each frequency
/// band 300-4000 Hz it compares the right and left level and turns that into an angle (-90 = left, +90 = right).
/// Energy is accumulated in a 37-bin angle histogram (5 degree bins); peaks in it are the "people" on the map.
/// Audio to the AirPods is written after the analysis of the samples it contains, so the gate decision applies
/// to the same audio it was made on.
final class Engine {
    static let nBins = 37                       // -90 ... +90 in 5 degree steps
    static func angle(ofBin b: Int) -> Float { Float(b) * 5 - 90 }

    // --- settings (written by UI thread, read by audio thread; plain words, fine for a prototype)
    var ildScale: Float = 8            // dB of right-vs-left difference that counts as fully left/right (sign = which side)
    var ildOffset: Float = 0           // the right-vs-left difference of a voice straight ahead
    var orientation: AVAudioSession.StereoOrientation = .portrait
    var listen = false                 // send audio to the AirPods
    var gateOn = false                 // "only the selected person"
    var selectedAngle: Float = .nan
    var sectorWidth: Float = 20        // degrees either side of the selected person

    // --- results (audio thread writes under lock, UI reads)
    struct Snapshot {
        var hist = [Float](repeating: 0, count: Engine.nBins)   // smoothed
        var inst = [Float](repeating: 0, count: Engine.nBins)   // this frame, fractions
        var levelL: Float = -100, levelR: Float = -100
        var ild: Float = 0, lagMs: Float = 0, ildNow: Float = 0
        var frameDB: Float = -100, noiseDB: Float = -60
        var speech = false
        var gate: Float = 1, selectedFrac: Float = 0
        var underruns = 0, bufferedMs: Float = 0, frames = 0
        var delayMs: Float = .nan
    }
    private var snap = Snapshot()
    private var snapLock = os_unfair_lock()
    func snapshot() -> Snapshot { os_unfair_lock_lock(&snapLock); defer { os_unfair_lock_unlock(&snapLock) }; return snap }

    let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode!
    private var source: AVAudioSourceNode!
    private(set) var sampleRate: Double = 48_000
    private(set) var channels = 1
    private(set) var routeText = ""
    private(set) var diag = ""            // what iOS offered / refused when asking for stereo
    private func note(_ s: String) { diag += s + "\n" }

    // --- analysis state (audio thread only)
    private let N = 2048, hop = 1024
    private var bufL: [Float], bufR: [Float], fill = 0
    private var win: [Float], tl: [Float], tr: [Float]
    private var inRe: [Float], inIm: [Float], outReL: [Float], outImL: [Float], outReR: [Float], outImR: [Float]
    private var dft: vDSP_DFT_Setup?
    private var hist = [Float](repeating: 0, count: Engine.nBins)
    private var inst = [Float](repeating: 0, count: Engine.nBins)
    private var noiseDB: Float = -60
    private var mono: [Float], monoFill = 0
    private var gain: Float = 1, gateHold: Float = 0
    private var smoothILD: Float = 0, smoothLag: Float = 0

    // --- output ring (single producer: sink thread, single consumer: render thread)
    private let ringSize = 1 << 16
    private let ring: UnsafeMutablePointer<Float>
    private var wIdx = 0, rIdx = 0
    private var underruns = 0

    // --- delay test
    private var inputCount = 0
    private var beepRequest = false, beepAt = -1, savedListen = false

    // --- recording
    private var recL: [Float] = [], recR: [Float] = [], recPos = 0, recActive = false
    var onRecordingDone: ((URL?) -> Void)?

    init() {
        bufL = .init(repeating: 0, count: N); bufR = bufL; tl = bufL; tr = bufL
        win = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: N, isHalfWindow: false)
        inRe = .init(repeating: 0, count: N / 2); inIm = inRe; outReL = inRe; outImL = inRe; outReR = inRe; outImR = inRe
        dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(N), .FORWARD)
        mono = .init(repeating: 0, count: 4096)
        ring = .allocate(capacity: 1 << 16); ring.initialize(repeating: 0, count: 1 << 16)
    }

    // MARK: - start / stop
    func start() throws {
        let s = AVAudioSession.sharedInstance()
        // A2DP (music link) for AirPods output keeps the phone's own mics as input.
        // Try session modes in order until iOS actually gives 2 input channels; log every attempt.
        diag = ""
        var gotStereo = false
        for mode in [AVAudioSession.Mode.default, .videoRecording, .measurement] {
            note("--- mode \(mode.rawValue)")
            do {
                try s.setCategory(.playAndRecord, mode: mode, options: [.allowBluetoothA2DP])
                try s.setPreferredSampleRate(48_000)
                try s.setPreferredIOBufferDuration(0.005)
                try s.setActive(true)
            } catch { note("session error: \(error.localizedDescription)"); continue }
            guard let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) else { note("no built-in mic"); continue }
            do { try s.setPreferredInput(mic) } catch { note("setPreferredInput: \(error.localizedDescription)") }
            for ds in mic.dataSources ?? [] {
                note("source \(ds.dataSourceName) orient=\(ds.orientation?.rawValue ?? "-") patterns=\((ds.supportedPolarPatterns ?? []).map { $0.rawValue })")
            }
            let stereo = (mic.dataSources ?? []).filter { $0.supportedPolarPatterns?.contains(.stereo) == true }
            // phone flat on the table, screen up: prefer the front (screen-side) source
            if let ds = stereo.first(where: { $0.orientation == .front }) ?? stereo.first {
                do { try ds.setPreferredPolarPattern(.stereo) } catch { note("setPolarPattern: \(error.localizedDescription)") }
                do { try mic.setPreferredDataSource(ds) } catch { note("setDataSource: \(error.localizedDescription)") }
                do { try s.setPreferredInputOrientation(orientation) } catch { note("setOrientation: \(error.localizedDescription)") }
                do { try s.setPreferredInputNumberOfChannels(min(2, s.maximumInputNumberOfChannels)) } catch { note("setChannels: \(error.localizedDescription)") }
            } else { note("no data source supports stereo") }
            let cur = s.currentRoute.inputs.first?.selectedDataSource
            note("result: channels=\(s.inputNumberOfChannels) max=\(s.maximumInputNumberOfChannels) src=\(cur?.dataSourceName ?? "-") pattern=\(cur?.selectedPolarPattern?.rawValue ?? "-")")
            if s.inputNumberOfChannels >= 2 { gotStereo = true; break }
        }
        note(gotStereo ? "STEREO OK" : "STEREO NOT AVAILABLE - direction will not work")

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        sampleRate = inFmt.sampleRate
        channels = Int(inFmt.channelCount)

        sink = AVAudioSinkNode { [unowned self] _, frames, abl in
            self.onInput(abl, Int(frames)); return noErr
        }
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        source = AVAudioSourceNode(format: outFmt) { [unowned self] _, _, frames, abl in
            self.render(abl, Int(frames)); return noErr
        }
        engine.attach(sink); engine.attach(source)
        engine.connect(input, to: sink, format: inFmt)
        engine.connect(source, to: engine.mainMixerNode, format: outFmt)
        try engine.start()

        let ins = s.currentRoute.inputs.map { "\($0.portName) [\($0.portType.rawValue)] src=\($0.selectedDataSource?.dataSourceName ?? "-") pattern=\($0.selectedDataSource?.selectedPolarPattern?.rawValue ?? "-")" }
        let outs = s.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        routeText = "IN: \(ins.joined(separator: ", "))\nOUT: \(outs.joined(separator: ", "))\nchannels \(channels), \(Int(sampleRate)) Hz\niOS latency: in \(Int(s.inputLatency * 1000)) ms, out \(Int(s.outputLatency * 1000)) ms, io buffer \(Int(s.ioBufferDuration * 1000)) ms\nmode: \(s.mode.rawValue)\n\n\(diag)"
    }

    func stop() {
        engine.stop()
        if let sink { engine.detach(sink) }
        if let source { engine.detach(source) }
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - audio thread
    private func onInput(_ ablPtr: UnsafePointer<AudioBufferList>, _ n: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
        guard let p0 = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let interleaved = abl.count == 1 && channels == 2
        let p1 = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) ?? p0 : p0
        for i in 0..<n {
            let l = interleaved ? p0[2 * i] : p0[i]
            let r = interleaved ? p0[2 * i + 1] : p1[i]
            bufL[fill] = l; bufR[fill] = r; fill += 1
            if monoFill < mono.count { mono[monoFill] = 0.5 * (l + r); monoFill += 1 }
            inputCount += 1
            if beepAt >= 0 && inputCount > beepAt + 480 && abs(l) + abs(r) > 0.2 {
                let d = Float(inputCount - beepAt) / Float(sampleRate) * 1000
                beepAt = -1; listen = savedListen
                os_unfair_lock_lock(&snapLock); snap.delayMs = d; os_unfair_lock_unlock(&snapLock)
            }
            if recActive {
                if recPos < recL.count { recL[recPos] = l; recR[recPos] = r; recPos += 1 }
                if recPos >= recL.count { recActive = false; DispatchQueue.global().async { self.saveRecording() } }
            }
            if fill == N {
                analyse()
                bufL.withUnsafeMutableBufferPointer { b in b.baseAddress!.update(from: b.baseAddress! + hop, count: N - hop) }
                bufR.withUnsafeMutableBufferPointer { b in b.baseAddress!.update(from: b.baseAddress! + hop, count: N - hop) }
                fill = N - hop
            }
        }
        if beepAt >= 0 && inputCount > beepAt + Int(sampleRate * 2) { beepAt = -1; listen = savedListen }   // not heard
    }

    private func analyse() {
        vDSP.multiply(bufL, win, result: &tl)
        vDSP.multiply(bufR, win, result: &tr)
        spectrum(tl, &outReL, &outImL)
        spectrum(tr, &outReR, &outImR)

        let df = Float(sampleRate) / Float(N)
        let kLo = Int(300 / df), kHi = min(N / 2 - 1, Int(4000 / df))
        for b in 0..<Engine.nBins { inst[b] = 0 }
        var eL: Float = 0, eR: Float = 0
        for k in kLo...kHi {
            let pl = outReL[k] * outReL[k] + outImL[k] * outImL[k]
            let pr = outReR[k] * outReR[k] + outImR[k] * outImR[k]
            eL += pl; eR += pr
            let ild = 10 * log10f((pr + 1e-12) / (pl + 1e-12))
            let x = (ild - ildOffset) / ildScale
            if abs(x) > 1.3 { continue }                       // outside the calibrated range: noise, ignore
            let a = max(-1, min(1, x)) * 90
            inst[Int(((a + 90) / 5).rounded())] += pl + pr
        }
        let tot = max(inst.reduce(0, +), 1e-12)
        for b in 0..<Engine.nBins { inst[b] /= tot }

        // frame level (time domain, both channels), noise floor follows the quiet moments
        let msL = vDSP.meanSquare(bufL), msR = vDSP.meanSquare(bufR)
        let frameDB = 10 * log10f(0.5 * (msL + msR) + 1e-12)
        if frameDB < noiseDB { noiseDB = frameDB } else { noiseDB += 0.02 }
        let speech = frameDB > noiseDB + 8

        let hopSec = Float(hop) / Float(sampleRate)
        let decay = expf(-hopSec / 1.5)
        let p = powf(10, frameDB / 10)
        for b in 0..<Engine.nBins { hist[b] = hist[b] * decay + (speech ? inst[b] * p : 0) }

        if speech {
            smoothILD = 0.85 * smoothILD + 0.15 * 10 * log10f((eR + 1e-12) / (eL + 1e-12))
            let maxLag = Int(sampleRate * 0.0006)
            var best: Float = -.infinity, bestK = 0
            for k in -maxLag...maxLag {
                var c: Float = 0
                let a = max(0, -k), n = N - abs(k)
                bufL.withUnsafeBufferPointer { l in bufR.withUnsafeBufferPointer { r in
                    vDSP_dotpr(l.baseAddress! + a, 1, r.baseAddress! + a + k, 1, &c, vDSP_Length(n)) } }
                if c > best { best = c; bestK = k }
            }
            smoothLag = 0.85 * smoothLag + 0.15 * Float(Double(bestK) / sampleRate * 1000)
        }

        // gate: open while the sound is mostly coming from the selected person's direction
        var selFrac: Float = 0
        var target: Float = 1
        if gateOn && !selectedAngle.isNaN {
            for b in 0..<Engine.nBins where abs(Engine.angle(ofBin: b) - selectedAngle) <= sectorWidth { selFrac += inst[b] }
            if speech && selFrac > 0.5 { gateHold = 0.3 }            // keep open 300 ms after their sound
            else if speech && selFrac < 0.3 { gateHold = 0 }         // someone else is clearly talking: close now
            else { gateHold = max(0, gateHold - hopSec) }
            target = gateHold > 0 ? 1 : 0
        }

        // write the audio of this hop to the AirPods ring, with the gain ramped to the new decision
        let out: Float = listen ? 1 : 0
        let count = monoFill
        if beepRequest {
            beepRequest = false; savedListen = listen; listen = false
            beepAt = inputCount
            let len = Int(sampleRate * 0.02)
            for i in 0..<len { push(0.8 * sinf(Float(i) * 2 * .pi * 2000 / Float(sampleRate))) }
        }
        for i in 0..<count {
            let g = gain + (target - gain) * Float(i + 1) / Float(count)
            push(mono[i] * g * out)
        }
        gain = target
        monoFill = 0
        // keep the buffered audio short: drop old samples beyond ~60 ms
        let maxBuf = Int(sampleRate * 0.06) + count
        if wIdx - rIdx > maxBuf { rIdx = wIdx - maxBuf }

        os_unfair_lock_lock(&snapLock)
        snap.hist = hist; snap.inst = inst
        snap.levelL = 10 * log10f(msL + 1e-12); snap.levelR = 10 * log10f(msR + 1e-12)
        snap.ild = smoothILD; snap.lagMs = smoothLag; snap.ildNow = 10 * log10f((eR + 1e-12) / (eL + 1e-12))
        snap.frameDB = frameDB; snap.noiseDB = noiseDB; snap.speech = speech
        snap.gate = target; snap.selectedFrac = selFrac
        snap.underruns = underruns; snap.bufferedMs = Float(wIdx - rIdx) / Float(sampleRate) * 1000
        snap.frames += 1
        os_unfair_lock_unlock(&snapLock)
    }

    private func spectrum(_ x: [Float], _ re: inout [Float], _ im: inout [Float]) {
        x.withUnsafeBufferPointer { xp in
            xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { c in
                inRe.withUnsafeMutableBufferPointer { r in inIm.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_ctoz(c, 2, &split, 1, vDSP_Length(N / 2))
                } }
            }
        }
        vDSP_DFT_Execute(dft!, inRe, inIm, &re, &im)
    }

    @inline(__always) private func push(_ v: Float) {
        ring[wIdx & (ringSize - 1)] = v; wIdx += 1
    }

    private func render(_ ablPtr: UnsafeMutablePointer<AudioBufferList>, _ n: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard let out = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let avail = wIdx - rIdx
        if avail < n { underruns += avail == 0 ? 0 : 1 }
        for i in 0..<n {
            if rIdx < wIdx { out[i] = ring[rIdx & (ringSize - 1)]; rIdx += 1 } else { out[i] = 0 }
        }
        for b in 1..<abl.count { abl[b].mData?.copyMemory(from: out, byteCount: n * 4) }
    }

    // MARK: - actions
    func measureDelay() { os_unfair_lock_lock(&snapLock); snap.delayMs = .nan; os_unfair_lock_unlock(&snapLock); beepRequest = true }

    func record(seconds: Double) {
        let n = Int(sampleRate * seconds)
        recL = .init(repeating: 0, count: n); recR = recL; recPos = 0; recActive = true
    }

    private func saveRecording() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("rec_\(Self.stamp()).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(recPos))!
            b.frameLength = AVAudioFrameCount(recPos)
            recL.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: recPos) }
            recR.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress!, count: recPos) }
            try f.write(from: b)
            onRecordingDone?(url)
        } catch { onRecordingDone?(nil) }
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f.string(from: Date())
    }
}
