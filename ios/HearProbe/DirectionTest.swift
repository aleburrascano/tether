import AVFoundation
import CoreMotion

/// Two checks for "can this phone tell where a voice comes from?"
///  1. Ask iOS whether 4-channel first-order ambisonics (true 360 degree sound field) capture is supported.
///  2. Record 10 s of the phone's stereo mics with a label (where the person is, phone orientation),
///     for offline analysis on the Mac.
enum DirectionTest {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func spatialCheck() -> String {
        var lines: [String] = []
        lines.append("device: \(UIDeviceName.model), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let dev = AVCaptureDevice.default(for: .audio) {
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                if #available(iOS 18.0, *) {
                    let foa = input.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
                    let st = input.isMultichannelAudioModeSupported(.stereo)
                    lines.append("360 ambisonics capture: \(foa ? "SUPPORTED" : "NOT supported")")
                    lines.append("stereo capture mode: \(st ? "supported" : "not supported")")
                } else { lines.append("iOS too old for the spatial capture API") }
            } catch { lines.append("could not open mic for capture check: \(error.localizedDescription)") }
        } else { lines.append("no audio capture device") }
        let s = AVAudioSession.sharedInstance()
        lines.append("max input channels (audio session): \(s.maximumInputNumberOfChannels)")
        let text = lines.joined(separator: "\n")
        try? text.write(to: docs.appendingPathComponent("spatial_check.txt"), atomically: true, encoding: .utf8)
        return text
    }

    /// Record `seconds` of stereo from the front mics. Blocks; call off the main thread. Returns a status line.
    static func recordStereo(label: String, sideways: Bool, seconds: Double = 10, startTime: Date? = nil) -> String {
        let s = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
            try s.setActive(true)
            guard let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return "no built-in mic" }
            try s.setPreferredInput(mic)
            let stereo = (mic.dataSources ?? []).filter { $0.supportedPolarPatterns?.contains(.stereo) == true }
            guard let ds = stereo.first(where: { $0.orientation == .front }) ?? stereo.first else { return "no stereo mic source" }
            try ds.setPreferredPolarPattern(.stereo)
            try mic.setPreferredDataSource(ds)
            try s.setPreferredInputOrientation(sideways ? .landscapeLeft : .portrait)
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            guard fmt.channelCount >= 2 else { return "only \(fmt.channelCount) channel(s) - stereo refused" }
            let url = docs.appendingPathComponent("dir_\(label)_\(sideways ? "sideways" : "upright")_\(Audio.stamp()).wav")
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                                                                   AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let total = AVAudioFramePosition(seconds * fmt.sampleRate)
            var written: AVAudioFramePosition = 0
            let done = DispatchSemaphore(value: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
                guard written < total else { return }
                try? file.write(from: buf)
                written += AVAudioFramePosition(buf.frameLength)
                if written >= total { done.signal() }
            }
            try engine.start()
            if let st = startTime {   // note when audio really started, relative to the heading clock
                try? String(format: "%.3f", Date().timeIntervalSince(st)).write(to: url.appendingPathExtension("start.txt"), atomically: true, encoding: .utf8)
            }
            _ = done.wait(timeout: .now() + seconds + 3)
            engine.inputNode.removeTap(onBus: 0); engine.stop()
            try? s.setActive(false)
            return "saved \(url.lastPathComponent) (\(fmt.channelCount) ch, \(Int(fmt.sampleRate)) Hz)"
        } catch {
            engine.stop()
            return "recording failed: \(error.localizedDescription)"
        }
    }
}

extension DirectionTest {
    /// Rotation test: record stereo for `seconds` while logging the phone's heading (gyro yaw) 50x a second.
    /// Spin the phone slowly one full turn on the table while a voice plays from a fixed spot.
    static func rotationTest(sideways: Bool, seconds: Double = 35) -> String {
        let motion = CMMotionManager()
        guard motion.isDeviceMotionAvailable else { return "no gyroscope" }
        let stamp = Audio.stamp()
        var yawLog = "t,yaw_deg\n"
        let t0 = Date()
        motion.deviceMotionUpdateInterval = 0.02
        let q = OperationQueue()
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: q) { m, _ in
            guard let m else { return }
            yawLog += String(format: "%.3f,%.2f\n", Date().timeIntervalSince(t0), m.attitude.yaw * 180 / .pi)
        }
        let r = recordStereo(label: "rotation_\(stamp)", sideways: sideways, seconds: seconds, startTime: t0)
        motion.stopDeviceMotionUpdates()
        q.waitUntilAllOperationsAreFinished()
        try? yawLog.write(to: docs.appendingPathComponent("rotation_\(stamp)_yaw.csv"), atomically: true, encoding: .utf8)
        return r + " + heading log"
    }
}

enum UIDeviceName {
    static var model: String {
        var sys = utsname(); uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
