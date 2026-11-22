import SwiftUI

/// Tether's one screen: who is talking, tap a voice to hear only that person.
/// Monochrome with one accent; nothing scrolls. Tuning and diagnostics live in the settings sheet.
enum Look {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let card = Color(red: 0.078, green: 0.078, blue: 0.090)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.957, green: 0.957, blue: 0.961)
    static let text2 = Color(red: 0.631, green: 0.631, blue: 0.667)
    static let text3 = Color(red: 0.388, green: 0.388, blue: 0.420)
    static let accent = Color(red: 0.247, green: 0.847, blue: 0.784)
    static let ease = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.32)
}

struct ContentView: View {
    @StateObject private var m = Model()
    @State private var showSettings = false
    @State private var history = [Float](repeating: 0, count: 44)
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Look.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                topBar.frame(height: 44)
                Spacer().frame(height: 14)
                Text(title)
                    .font(.system(size: 31, weight: .light)).tracking(-0.6)
                    .foregroundStyle(m.running && m.speakerWarning ? Color.orange : Look.text).lineLimit(1).minimumScaleFactor(0.7)
                    .id(title).transition(.opacity.combined(with: .offset(y: 8)))
                Text(subtitle)
                    .font(.system(size: 14)).foregroundStyle(Look.text2)
                    .frame(height: 42, alignment: .topLeading).padding(.top, 4)
                Levels(history: history, tone: tone).frame(maxHeight: .infinity).padding(.vertical, 6)
                    .opacity(m.running ? 1 : 0.3)
                voices.frame(height: 96)
                Spacer().frame(height: 14)
                startStop.frame(maxWidth: .infinity).frame(height: 52)
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
            .animation(Look.ease, value: title)
        }
        .preferredColorScheme(.dark)
        .onAppear { m.loadModel() }
        .onReceive(tick) { _ in
            // -60 dB and below = 0, -15 dB = 1 (what the level bars show)
            let v = m.running ? max(0, min(1, (m.level + 60) / 45)) : 0
            history.removeFirst(); history.append(v)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(m: m).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private var tone: Color { !m.running ? Look.text3 : m.speakerWarning ? Color.orange : (m.bubbles.contains { $0.talking } ? Look.accent : Look.text2) }

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle().fill(tone).frame(width: 8, height: 8)
            Text(!m.modelReady ? "Loading" : (!m.running ? "Paused" : (m.speakerWarning ? "No headphones" : "Listening")))
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Look.text2)
            Spacer()
            if m.running {
                // "that sounded wrong": saves the last 10 s for a look afterwards
                Button { m.mark() } label: {
                    Image(systemName: m.markText.isEmpty ? "flag" : "flag.fill").font(.system(size: 18))
                        .foregroundStyle(m.markText.isEmpty ? Look.text3 : Look.accent).frame(width: 40, height: 44)
                }
                .accessibilityLabel("Mark this moment")
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 20)).foregroundStyle(Look.text2).frame(width: 40, height: 44, alignment: .trailing)
            }
            .accessibilityLabel("Settings")
        }
    }

    private var title: String {
        if !m.modelReady { return "Getting ready" }
        if !m.running { return "Not listening" }
        if m.speakerWarning { return "Connect headphones" }
        if let s = m.selected { return m.filterActive ? "Only voice \(s + 1)" : "Learning voice \(s + 1)" }
        return m.bubbles.isEmpty ? "Listening" : "Hearing everyone"
    }

    private var subtitle: String {
        if !m.error.isEmpty { return m.error }
        if !m.modelReady { return m.modelStatus }
        if !m.running { return "Put the phone on the table and press play." }
        if m.speakerWarning { return "Nothing is being played. Without headphones the phone would feed back into its own microphone." }
        if m.selected != nil { return m.filterActive ? "Everyone else is turned down. Tap the number again to hear all voices." : "Keep them talking for a couple of seconds." }
        return m.bubbles.isEmpty ? "A voice appears after someone talks for a moment." : "Tap a voice to hear only that person."
    }

    private var voices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOICES").font(.system(size: 12, weight: .medium)).tracking(0.8).foregroundStyle(Look.text3)
            HStack(spacing: 12) {
                ForEach(m.bubbles) { b in
                    VoiceDot(number: b.id + 1, talking: b.talking, chosen: m.selected == b.id,
                             dimmed: m.selected != nil && m.selected != b.id, learning: m.selected == b.id && !m.filterActive)
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(Look.ease) { m.tap(b) }
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if m.bubbles.isEmpty {
                    Text(m.running ? "Nobody yet" : " ").font(.system(size: 14)).foregroundStyle(Look.text3).frame(height: 56)
                }
                Spacer(minLength: 0)
            }
            .animation(Look.ease, value: m.bubbles.map { $0.id })
        }
    }

    private var startStop: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(Look.ease) { m.toggle() }
        } label: {
            ZStack {
                Circle().fill(m.running ? Color.white.opacity(0.06) : Look.accent)
                Circle().stroke(m.running ? Color.white.opacity(0.14) : Look.accent, lineWidth: 1)
                Image(systemName: m.running ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(m.running ? Look.text : Look.bg).offset(x: m.running ? 0 : 1)
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(Press())
        .disabled(!m.modelReady).opacity(m.modelReady ? 1 : 0.4)
        .accessibilityLabel(m.running ? "Pause listening" : "Start listening")
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The room's level over the last few seconds, newest on the right.
struct Levels: View {
    let history: [Float]
    let tone: Color
    var body: some View {
        GeometryReader { g in
            let n = history.count
            let step = g.size.width / CGFloat(max(1, n))
            let tall = min(g.size.height, 190)
            ZStack(alignment: .topLeading) {
                ForEach(0..<n, id: \.self) { i in
                    let h = max(3, tall * CGFloat(min(1, history[i])))
                    Capsule()
                        .fill(i > n - 4 ? tone : Look.text2)
                        .frame(width: max(2, step - 4), height: h)
                        .opacity(0.1 + 0.8 * Double(i) / Double(max(1, n - 1)))
                        .position(x: CGFloat(i) * step + step / 2, y: g.size.height / 2)
                }
            }
            .animation(.linear(duration: 0.1), value: history)
        }
    }
}

/// One recognised voice: lights up while that person talks, fills in when it is the one you hear.
struct VoiceDot: View {
    let number: Int
    let talking: Bool
    let chosen: Bool
    let dimmed: Bool
    let learning: Bool
    @State private var breathe = false

    var body: some View {
        let d: CGFloat = talking || chosen ? 56 : 48
        ZStack {
            Circle().fill(chosen ? Look.accent : (talking ? Look.accent.opacity(0.16) : Color.white.opacity(0.04)))
            Circle().stroke(chosen ? Look.accent : (talking ? Look.accent.opacity(0.7) : Look.line), lineWidth: 1)
            Text("\(number)").font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(chosen ? Look.bg : (talking ? Look.accent : Look.text2))
        }
        .frame(width: d, height: d)
        .frame(width: 56, height: 56)
        .opacity(dimmed ? 0.4 : (learning ? (breathe ? 0.55 : 1) : 1))
        .animation(Look.ease, value: talking)
        .animation(Look.ease, value: chosen)
        .onChange(of: learning) { _, on in
            if on { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathe = true } } else { breathe = false }
        }
        .contentShape(Circle())
        .accessibilityLabel("Voice \(number)" + (talking ? ", talking" : "") + (chosen ? ", selected" : ""))
    }
}

// MARK: - Settings (tuning + diagnostics)

struct SettingsSheet: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var boostDraft: Double? = nil
    @State private var delayDraft: Double? = nil
    @State private var sideways = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sound") {
                    HStack {
                        Text("Boost")
                        Slider(value: Binding(get: { boostDraft ?? m.boost }, set: { boostDraft = $0.rounded(); m.audio.boostDB = Float($0.rounded()) }), in: 0...30,
                               onEditingChanged: { editing in if !editing, let d = boostDraft { m.setBoost(d); boostDraft = nil } })
                        Text(String(format: "+%.0f dB", boostDraft ?? m.boost)).font(.callout.monospacedDigit()).frame(width: 62, alignment: .trailing)
                    }
                    HStack {
                        Text("Delay")
                        Slider(value: Binding(get: { delayDraft ?? m.delay }, set: { delayDraft = ($0 * 10).rounded() / 10 }), in: 0...1.5,
                               onEditingChanged: { editing in if !editing, let d = delayDraft { m.setDelay(d); delayDraft = nil } })
                        Text(String(format: "%.1f s", delayDraft ?? m.delay)).font(.callout.monospacedDigit()).frame(width: 62, alignment: .trailing)
                    }
                    Toggle("Remove background noise and echo", isOn: Binding(get: { m.denoise }, set: { m.setDenoise($0) }))
                    Toggle("Even out loudness per person", isOn: Binding(get: { m.autoLevel }, set: { m.setAutoLevel($0) }))
                }
                Section {
                    Toggle("Tell similar voices apart", isOn: Binding(get: { m.personCheck }, set: { m.setPersonCheck($0) }))
                    Toggle("Smoothed mute", isOn: Binding(get: { m.smoothing }, set: { m.setSmoothing($0) }))
                    Toggle("Voiceprint-checked clip", isOn: Binding(get: { m.clipCheck }, set: { m.setClipCheck($0) }))
                    Toggle("Subtract the interrupter", isOn: Binding(get: { m.subtract }, set: { m.setSubtract($0) }))
                    Toggle("Speaker model v2 (crowded overlap)", isOn: Binding(get: { m.modelV2 }, set: { m.setModelV2($0) }))
                } header: { Text("Voice handling") } footer: {
                    Text("Filter switches apply from the next voice you tap. The model switch needs the app reopened.")
                }
                Section("Right now") {
                    mono(m.filterActive ? String(format: "filter on, clip %.1f s, refreshed %d times", m.soloSec, m.filterRefreshes)
                                        : (m.selected == nil ? "filter waiting for a tap" : String(format: "filter learning, %.1f of 2 s", m.soloSec)))
                    mono(String(format: "filter %.0f ms per 40 ms, ready %.0f%%, load %.0f%%", m.filterMs, m.filterCoverage * 100, m.filterLoad * 100))
                    mono(String(format: "speaker model %.0f ms, %.2f s behind", m.procMs, m.modelLag))
                    mono(String(format: "quality %@  clip score %.2f", m.quality < 0 ? "-" : String(format: "%.2f", m.quality), m.clipScore))
                    mono(m.personText.isEmpty ? "voice check: -" : "voice check: \(m.personText)")
                    mono(String(format: "mute %.2f  buffered %.2f s  mic %.0f dB", m.gainNow, m.buffered, m.level))
                    mono("voiceprints \(Voiceprint.shared.status), noise remover \(Denoiser.shared.status)")
                    if let e = m.extractor.loadError { mono("filter load error: \(e)") }
                    mono(m.route.isEmpty ? "not started" : m.route)
                    ProbChart(recent: m.recent).frame(height: 90)
                }
                Section("Recording and log") {
                    Toggle("Record whole session", isOn: Binding(get: { m.recordSession }, set: { m.setRecordSession($0) }))
                    Button("Record 20 s") { m.record() }.disabled(!m.running)
                    if !m.recordText.isEmpty { mono(m.recordText) }
                    mono("log: \(m.logName.isEmpty ? "-" : m.logName)")
                }
                Section("Direction checks") {
                    Button("Check 360 support") { m.runSpatialCheck() }
                    if !m.spatialText.isEmpty { mono(m.spatialText) }
                    Toggle("Phone sideways", isOn: $sideways)
                    Button(m.dirBusy ? "Recording..." : "Rotation test (35 s)") { m.rotationTest(sideways: sideways) }.disabled(m.dirBusy)
                    HStack {
                        ForEach(["left", "front", "right"], id: \.self) { side in
                            Button(side.capitalized) { m.recordDirection(side, sideways: sideways) }.buttonStyle(.bordered).disabled(m.dirBusy)
                        }
                    }
                    if !m.dirStatus.isEmpty { mono(m.dirStatus) }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(Look.accent) } }
            .tint(Look.accent)
        }
        .preferredColorScheme(.dark)
    }

    func mono(_ s: String) -> some View { Text(s).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary) }
}

let slotColors: [Color] = [Look.accent, Color(white: 0.85), Color(white: 0.6), Color(white: 0.4)]

struct ProbChart: View {
    let recent: [[Float]]
    var body: some View {
        Canvas { ctx, size in
            guard recent.count > 1 else { return }
            let dx = size.width / CGFloat(recent.count - 1)
            var mid = Path(); mid.move(to: CGPoint(x: 0, y: size.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(mid, with: .color(.gray.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4]))
            for s in 0..<4 {
                var p = Path()
                for (i, fr) in recent.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * dx, y: size.height * (1 - CGFloat(fr.count > s ? fr[s] : 0)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                ctx.stroke(p, with: .color(slotColors[s]), lineWidth: 1.5)
            }
        }
    }
}
