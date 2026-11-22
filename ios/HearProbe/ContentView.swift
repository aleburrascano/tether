import SwiftUI

/// Tether's one screen: the voices on top (tap one to hear only that person), a brain illustration in the
/// middle, the room's sound as bars at the bottom, and the listening agent's question over the bars.
/// Nothing scrolls. Tuning and diagnostics live in the settings sheet.
enum Look {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let card = Color(red: 0.078, green: 0.078, blue: 0.090)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.957, green: 0.957, blue: 0.961)
    static let text2 = Color(red: 0.631, green: 0.631, blue: 0.667)
    static let text3 = Color(red: 0.388, green: 0.388, blue: 0.420)
    static let accent = Color(red: 0.247, green: 0.847, blue: 0.784)
    static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)      // the voice you picked, and the agent
    static let ease = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.32)
}

struct ContentView: View {
    @StateObject private var m = Model()
    @StateObject private var brain = BrainModel()
    @StateObject private var agent = Agent()
    @State private var showSettings = false
    @State private var history = [Float](repeating: 0, count: 44)
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    /// Each voice sits a little off the row, so they look placed rather than lined up.
    private static let drop: [CGFloat] = [4, 22, 10, 26], shift: [CGFloat] = [-5, 6, -2, 7]

    var body: some View {
        ZStack {
            Look.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.frame(height: 44)
                stage.frame(maxHeight: .infinity)
                bottom.frame(height: 150)
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .onAppear { m.loadModel() }
        .onReceive(tick) { _ in
            // -60 dB and below = 0, -15 dB = 1 (what the level bars show)
            let v = m.running ? max(0, min(1, (m.level + 60) / 45)) : 0
            history.removeFirst(); history.append(v)
            brain.step(heard: heard(v), dt: 0.1)
            agent.tick(m)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(m: m).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    /// How much sound reaches the headphones, 0...1: the room when you hear everyone, only the picked
    /// voice's moments when you picked one, nothing without headphones.
    private func heard(_ room: Float) -> Float {
        guard m.running, !m.speakerWarning else { return 0 }
        guard let s = m.selected else { return room }
        return (m.bubbles.first { $0.id == s }?.talking ?? false) ? room : room * 0.08
    }

    private var tone: Color { !m.running ? Look.text3 : m.speakerWarning ? Look.orange : (m.bubbles.contains { $0.talking } ? Look.orange : Look.text2) }

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer()
            if m.running {
                // "that sounded wrong": saves the last 10 s for a look afterwards
                Button { m.mark() } label: {
                    Image(systemName: m.markText.isEmpty ? "flag" : "flag.fill").font(.system(size: 17))
                        .foregroundStyle(m.markText.isEmpty ? Look.text3 : Look.orange).frame(width: 36, height: 44)
                }
                .accessibilityLabel("Mark this moment")
            }
            startStop
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 20)).foregroundStyle(Look.text2).frame(width: 40, height: 44, alignment: .trailing)
            }
            .accessibilityLabel("Settings")
        }
    }

    // The voices on top, the brain in the middle; the voice you picked is joined to the brain by a line of sound.
    private var stage: some View {
        GeometryReader { geo in
            let n = max(1, m.bubbles.count)
            let size: CGFloat = n <= 3 ? 62 : 54
            let brainSide = min(geo.size.width, geo.size.height - 110)
            let brainMid = CGPoint(x: geo.size.width / 2, y: 110 + (geo.size.height - 110) / 2)
            let place = { (i: Int, id: Int) -> CGPoint in
                CGPoint(x: geo.size.width * (CGFloat(i) + 0.5) / CGFloat(n) + Self.shift[id & 3], y: 16 + size / 2 + Self.drop[id & 3])
            }
            ZStack {
                ForEach(Array(m.bubbles.enumerated()), id: \.element.id) { i, b in
                    if m.selected == b.id {
                        SoundLine(from: place(i, b.id), to: CGPoint(x: brainMid.x - brainSide * 0.04, y: brainMid.y + brainSide * 0.04),
                                  lively: b.talking && m.filterActive ? 1 : 0.25, seed: Double(b.id))
                    }
                }
                Brain3DView(brain: brain).frame(width: brainSide, height: brainSide).position(brainMid)
                    .opacity(m.running ? 1 : 0.55)
                    .accessibilityLabel("Illustration of a brain that brightens with the sound you hear")
                ForEach(Array(m.bubbles.enumerated()), id: \.element.id) { i, b in
                    let chosen = m.selected == b.id
                    ZStack {
                        WavyBlob(colour: chosen ? Look.orange : Color(white: 0.56), size: size, level: b.talking ? 1 : 0, seed: Double(b.id) * 1.7)
                            .frame(width: size * 1.7, height: size * 1.7)
                        Text("\(b.id + 1)").font(.system(size: 19, weight: .semibold, design: .monospaced)).foregroundStyle(chosen ? Look.bg : .white)
                    }
                    .opacity(m.selected != nil && !chosen ? 0.45 : 1)
                    .contentShape(Circle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(Look.ease) { m.tap(b) }
                    }
                    .position(place(i, b.id))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Voice \(b.id + 1)" + (b.talking ? ", talking" : "") + (chosen ? ", selected" : ""))
                    .accessibilityAddTraits(.isButton)
                }
            }
            .animation(Look.ease, value: m.bubbles.map { $0.id })
        }
    }

    /// The sound of the room as bars. Anything you must know (still loading, no headphones, an error)
    /// is written over them in a few big words; the agent's question sits on top of everything.
    private var bottom: some View {
        ZStack {
            Levels(history: history, tone: tone).padding(.vertical, 6).opacity(m.running ? (notice == nil ? 1 : 0.25) : 0.3)
            if let notice, agent.alert == nil {
                VStack(spacing: 4) {
                    Text(notice.0).font(.system(size: 28, weight: .semibold)).tracking(-0.5).foregroundStyle(m.speakerWarning && m.running ? Look.orange : Look.text)
                    if !notice.1.isEmpty { Text(notice.1).font(.system(size: 15)).foregroundStyle(Look.text2).multilineTextAlignment(.center).lineLimit(2) }
                }
            }
            if let a = agent.alert, m.running {
                AgentCard(alert: a) { yes in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if yes, let v = a.voice, m.selected != v, let b = m.bubbles.first(where: { $0.id == v }) { m.tap(b) }
                    withAnimation(Look.ease) { agent.dismiss() }
                }
                .transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .animation(Look.ease, value: agent.alert)
    }

    private var notice: (String, String)? {
        if !m.error.isEmpty { return ("Problem", m.error) }
        if !m.modelReady { return ("Getting ready", m.modelStatus) }
        if !m.running { return ("Press play", "") }
        if m.speakerWarning { return ("Connect headphones", "Nothing is played without them.") }
        if m.selected != nil && !m.filterActive { return ("Learning the voice", "Keep them talking.") }
        return nil
    }

    private var startStop: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(Look.ease) { m.toggle() }
        } label: {
            ZStack {
                Circle().fill(m.running ? Color.white.opacity(0.06) : Look.orange)
                Circle().stroke(m.running ? Color.white.opacity(0.14) : Look.orange, lineWidth: 1)
                Image(systemName: m.running ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(m.running ? Look.text : Look.bg).offset(x: m.running ? 0 : 1)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(Press())
        .disabled(!m.modelReady).opacity(m.modelReady ? 1 : 0.4)
        .accessibilityLabel(m.running ? "Pause listening" : "Start listening")
    }
}

/// The agent's question: who it is, a few words on what it is about, Yes or No.
struct AgentCard: View {
    let alert: Agent.Alert
    let answer: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(alert.who).font(.system(size: 30, weight: .semibold)).tracking(-0.6).foregroundStyle(Look.orange).lineLimit(1).minimumScaleFactor(0.7)
            Text(alert.summary.isEmpty ? "Want to hear them?" : "\(alert.summary). Hear them?").font(.system(size: 17)).foregroundStyle(Look.text).lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 12) {
                Button { answer(true) } label: {
                    Text("Yes").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(red: 0.10, green: 0.07, blue: 0.02))
                        .frame(maxWidth: .infinity).frame(height: 44).background(Look.orange, in: RoundedRectangle(cornerRadius: 14))
                }
                Button { answer(false) } label: {
                    Text("No").font(.system(size: 18, weight: .semibold)).foregroundStyle(Look.text)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .buttonStyle(Press()).padding(.top, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Look.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Look.orange, lineWidth: 1.5))
    }
}

/// A voice drawn as a soft shape whose edge ripples; livelier while that person talks.
struct WavyBlob: View {
    let colour: Color
    let size: CGFloat
    let level: Double
    let seed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, canvas in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let centre = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let radius = size / 2 * (1 + 0.16 * level), wobble = size * (0.055 + 0.13 * level)
                func outline(_ r: CGFloat, _ w: CGFloat, _ shift: Double) -> Path {
                    var path = Path()
                    for i in 0...64 {
                        let a = Double(i) / 64 * 2 * .pi
                        let rr = r + CGFloat(sin(a * 3 + t * 2.1 + seed + shift)) * w + CGFloat(sin(a * 5 - t * 1.5 + seed * 0.7)) * w * 0.6
                        let point = CGPoint(x: centre.x + CGFloat(cos(a)) * rr, y: centre.y + CGFloat(sin(a)) * rr)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    return path
                }
                context.fill(outline(radius * 1.2, wobble * 1.05, 1.3), with: .color(colour.opacity(0.10 + 0.22 * level)))
                context.fill(outline(radius, wobble, 0), with: .radialGradient(Gradient(colors: [colour.opacity(0.98), colour.opacity(0.62)]),
                             center: CGPoint(x: centre.x - radius * 0.3, y: centre.y - radius * 0.35), startRadius: 0, endRadius: radius * 1.5))
                context.fill(Path(ellipseIn: CGRect(x: centre.x - radius * 0.52, y: centre.y - radius * 0.56, width: radius * 0.42, height: radius * 0.36)),
                             with: .color(.white.opacity(0.28)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The line of sound from the picked voice into the brain: three strands that ripple like a waveform,
/// pinned at both ends. Drawn behind the brain.
struct SoundLine: View {
    let from: CGPoint, to: CGPoint
    let lively: Double, seed: Double
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let dx = to.x - from.x, dy = to.y - from.y, length = max(1, hypot(dx, dy))
                let nx = -dy / length, ny = dx / length
                for strand in 0..<3 {
                    var path = Path()
                    let k = Double(strand)
                    for i in 0...60 {
                        let u = Double(i) / 60
                        let pinned = sin(u * .pi)                                   // no movement at the ends
                        let swing = (sin(u * (9 + 3 * k) - t * (4.2 + k) + seed * 2 + k) + 0.5 * sin(u * 21 + t * 6.5 + k * 1.9)) * (4 + 9 * lively) * pinned
                        let point = CGPoint(x: from.x + dx * u + nx * swing, y: from.y + dy * u + ny * swing)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(Look.orange.opacity(0.85 - 0.25 * k)), style: StrokeStyle(lineWidth: 2.4 - 0.6 * k, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The room's level over the last few seconds, newest on the right. One drawing pass (cheap: the audio
/// models need the processor more than this does).
struct Levels: View {
    let history: [Float]
    let tone: Color
    var body: some View {
        Canvas { ctx, size in
            let n = history.count
            let step = size.width / CGFloat(max(1, n))
            let tall = min(size.height, 190)
            for i in 0..<n {
                let h = max(3, tall * CGFloat(min(1, history[i])))
                let w = max(2, step - 4)
                let r = CGRect(x: CGFloat(i) * step + (step - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                let a = 0.1 + 0.8 * Double(i) / Double(max(1, n - 1))
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color((i > n - 4 ? tone : Look.text2).opacity(a)))
            }
        }
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
                    Toggle("Brighten the selected voice", isOn: Binding(get: { m.brighten }, set: { m.setBrighten($0) }))
                }
                Section {
                    Toggle("Voiceprint check on voices (experimental)", isOn: Binding(get: { m.personCheck }, set: { m.setPersonCheck($0) }))
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
