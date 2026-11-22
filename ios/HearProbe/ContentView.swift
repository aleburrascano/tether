import SwiftUI

struct ContentView: View {
    @StateObject private var m = Model()

    var body: some View {
        TabView {
            HearScreen(m: m).tabItem { Label("Hear", systemImage: "person.wave.2") }
            DebugScreen(m: m).tabItem { Label("Debug", systemImage: "waveform.path.ecg") }
        }
        .onAppear { m.loadModel() }
    }
}

let slotColors: [Color] = [Color(red: 1.0, green: 0.55, blue: 0.25), Color(red: 0.25, green: 0.80, blue: 0.55),
                           Color(red: 0.60, green: 0.45, blue: 1.0), Color(red: 1.0, green: 0.40, blue: 0.62)]

// MARK: - Hear

struct HearScreen: View {
    @ObservedObject var m: Model

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.10), Color(red: 0.09, green: 0.10, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 14) {
                header
                Ring(m: m).frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).padding(.horizontal, 8)
                Text(hint).font(.footnote).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(minHeight: 34)
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
    }

    var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("VoiceTap").font(.title2.bold())
                Spacer()
                Label(m.running ? (m.speakerWarning ? "No headphones" : (m.audio.outputName.isEmpty ? "Headphones" : m.audio.outputName)) : "Not listening",
                      systemImage: m.speakerWarning && m.running ? "headphones.slash" : "headphones")
                    .font(.caption.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(m.speakerWarning && m.running ? .orange : .white.opacity(0.8))
            }
            HStack {
                Text(status).font(.headline).foregroundStyle(.white.opacity(0.9))
                Spacer()
                if m.running {
                    Button { m.mark() } label: {
                        Label(m.markText.isEmpty ? "Mark" : "Marked", systemImage: m.markText.isEmpty ? "flag" : "flag.fill")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.yellow.opacity(m.markText.isEmpty ? 0.15 : 0.35), in: Capsule())
                    }.foregroundStyle(.yellow)
                }
            }
        }
    }

    var controls: some View {
        VStack(spacing: 14) {
            BoostSlider(m: m)
            Button { m.toggle() } label: {
                Text(m.running ? "Stop" : (m.modelReady ? "Start listening" : "Loading..."))
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).tint(m.running ? Color(white: 0.3) : .blue)
            .disabled(!m.modelReady)
            if !m.error.isEmpty { Text(m.error).font(.footnote).foregroundStyle(.red) }
            if !m.modelReady { Text(m.modelStatus).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
    }

    var status: String {
        if !m.running { return "Put the phone on the table and start." }
        if let s = m.selected { return m.filterActive ? "Hearing Person \(s + 1)" : "Hearing Person \(s + 1) - getting their voice..." }
        if m.bubbles.isEmpty { return "Listening..." }
        return "Hearing everyone"
    }

    var hint: String {
        if !m.running { return "People appear around the phone as they talk." }
        if m.running && m.speakerWarning { return "Sound is off without headphones (the speaker would feed back). Connect AirPods and it turns on." }
        if m.bubbles.isEmpty { return "A person appears after they talk for a moment." }
        if m.selected != nil { return "Tap them again to hear everyone. Spots show who, not where they sit." }
        return "Tap a person to hear only them. Spots show who, not where they sit."
    }
}

/// The phone in the middle, each person on a fixed spot of the ring: 1 top, 2 right, 3 bottom, 4 left.
struct Ring: View {
    @ObservedObject var m: Model
    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let r = size * 0.31
            ZStack {
                Circle().stroke(.white.opacity(0.07), lineWidth: 1).frame(width: 2 * r, height: 2 * r).position(c)
                Circle().stroke(.white.opacity(0.04), lineWidth: 1).frame(width: 1.3 * r, height: 1.3 * r).position(c)
                PhoneGlyph(listening: m.running).position(c)
                ForEach(m.bubbles) { b in
                    let a = Double(b.id) * .pi / 2 - .pi / 2          // slot 0 top, then clockwise
                    PersonDot(b: b, selected: m.selected == b.id, dimmed: m.selected != nil && m.selected != b.id,
                              learning: m.selected == b.id && !m.filterActive, size: size * 0.21)
                        .position(x: c.x + r * cos(a), y: c.y + r * sin(a))
                        .onTapGesture { withAnimation(.spring(duration: 0.35)) { m.tap(b) } }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4), value: m.bubbles.map { $0.id })
        }
    }
}

struct PhoneGlyph: View {
    let listening: Bool
    var body: some View {
        ZStack {
            if listening {
                Circle().fill(Color.blue.opacity(0.10)).frame(width: 96, height: 96)
            }
            RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.7), lineWidth: 2).frame(width: 30, height: 54)
            Capsule().fill(.white.opacity(0.7)).frame(width: 10, height: 3).offset(y: -21)
        }
    }
}

struct PersonDot: View {
    let b: Model.Bubble
    let selected: Bool
    let dimmed: Bool
    let learning: Bool
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        let col = slotColors[b.id]
        let d = selected ? size * 1.18 : size
        ZStack {
            if b.talking {
                Circle().fill(col.opacity(0.28)).frame(width: d * 1.45, height: d * 1.45)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                    .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true } }
                    .onDisappear { pulse = false }
            }
            Circle().fill(LinearGradient(colors: [col, col.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                .frame(width: d, height: d)
                .shadow(color: selected ? col.opacity(0.8) : .clear, radius: 16)
            if selected { Circle().stroke(.white, lineWidth: 3).frame(width: d + 10, height: d + 10) }
            Text("\(b.id + 1)").font(.system(size: d * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .overlay(alignment: .bottom) {
            Text(selected ? (learning ? "getting voice..." : "HEARING") : (b.talking ? "talking" : " "))
                .font(.caption2.weight(selected ? .bold : .regular)).foregroundStyle(.white.opacity(selected ? 0.95 : 0.6))
                .offset(y: 6)
        }
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Circle())
    }
}

struct BoostSlider: View {
    @ObservedObject var m: Model
    @State private var draft: Double? = nil
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            Slider(value: Binding(get: { draft ?? m.boost }, set: { draft = $0.rounded(); m.audio.boostDB = Float($0.rounded()) }), in: 0...30,
                   onEditingChanged: { editing in if !editing, let d = draft { m.setBoost(d); draft = nil } })
            Text(String(format: "+%.0f dB", draft ?? m.boost)).font(.callout.monospacedDigit()).frame(width: 60)
        }
    }
}

// MARK: - Debug

struct DebugScreen: View {
    @ObservedObject var m: Model
    @State private var delayDraft: Double? = nil
    @State private var sideways = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Debug").font(.largeTitle.bold())

                box("Delay") {
                    HStack {
                        Slider(value: Binding(get: { delayDraft ?? m.delay }, set: { delayDraft = ($0 * 10).rounded() / 10 }), in: 0...1.5,
                               onEditingChanged: { editing in if !editing, let d = delayDraft { m.setDelay(d); delayDraft = nil } })
                        Text(String(format: "%.1f s", delayDraft ?? m.delay)).font(.body.monospacedDigit()).frame(width: 52)
                    }
                    Text("Plus ~0.2 s for Bluetooth.").font(.caption).foregroundStyle(.secondary)
                }

                box("Improvements (compare on/off)") {
                    Toggle("Smoothed mute (NVIDIA settings)", isOn: Binding(get: { m.smoothing }, set: { m.setSmoothing($0) }))
                    Toggle("Voiceprint-checked clip", isOn: Binding(get: { m.clipCheck }, set: { m.setClipCheck($0) }))
                    Toggle("Subtract the interrupter", isOn: Binding(get: { m.subtract }, set: { m.setSubtract($0) }))
                    Toggle("Remove background noise + echo", isOn: Binding(get: { m.denoise }, set: { m.setDenoise($0) }))
                    Toggle("Auto loudness per person", isOn: Binding(get: { m.autoLevel }, set: { m.setAutoLevel($0) }))
                    Toggle("Record whole session (for offline tests)", isOn: Binding(get: { m.recordSession }, set: { m.setRecordSession($0) }))
                    Toggle("Speaker model v2 (crowded overlap)", isOn: Binding(get: { m.modelV2 }, set: { m.setModelV2($0) }))
                    Text("The model switch applies after you close and reopen the app (first time: downloads ~245 MB).")
                        .font(.caption).foregroundStyle(.secondary)
                    mono(String(format: "quality (played audio vs person): %@   clip score %.2f",
                                m.quality < 0 ? "-" : String(format: "%.2f", m.quality), m.clipScore))
                    mono(String(format: "subtracting: %@   filter load %.0f%% of real time",
                                m.subtracting.map { "Person \($0 + 1)" } ?? "nobody", m.filterLoad * 100))
                    mono("voiceprint model: \(Voiceprint.shared.status)   noise remover: \(Denoiser.shared.status)")
                    mono(String(format: "auto loudness now %+.1f dB   noise remover %.1f ms per piece", m.autoGainDB, Denoiser.shared.lastMs))
                    Text("Noise remover and the filter switches apply from the next person you tap.").font(.caption).foregroundStyle(.secondary)
                }

                box("Who the model thinks is talking (last 8 s)") {
                    ProbChart(recent: m.recent).frame(height: 110)
                    HStack {
                        ForEach(0..<4, id: \.self) { i in
                            Text(String(format: "P%d %.2f", i + 1, m.latest.count > i ? m.latest[i] : 0))
                                .font(.caption.monospacedDigit()).foregroundStyle(slotColors[i])
                        }
                    }
                }

                box("Numbers") {
                    mono(m.filterActive ? String(format: "voice filter: ON, clip %.1f s of solo speech, refreshed %d times", m.soloSec, m.filterRefreshes)
                                        : (m.selected == nil ? "voice filter: waiting for a tap" : String(format: "voice filter: learning, %.1f of 2 s", m.soloSec)))
                    mono(String(format: "filter %.0f ms per 40 ms, filtered audio ready %.0f%% of the time", m.filterMs, m.filterCoverage * 100))
                    mono(String(format: "speaker model %.0f ms per update, %.2f s behind the mic", m.procMs, m.modelLag))
                    mono(String(format: "mute %.2f   buffered %.2f s   mic %.0f dB", m.gainNow, m.buffered, m.level))
                    if let e = m.extractor.loadError { mono("filter load error: \(e)") }
                    mono(m.route.isEmpty ? "not started" : m.route)
                }

                box("Direction checks") {
                    Button("Check 360 support") { m.runSpatialCheck() }
                    if !m.spatialText.isEmpty { mono(m.spatialText) }
                    Divider()
                    Button(m.dirBusy ? "Recording..." : "Rotation test (35 s)") { m.rotationTest(sideways: sideways) }
                        .buttonStyle(.borderedProminent).disabled(m.dirBusy)
                    Text("Phone flat ~1 m from the Mac while the Mac plays a voice. Tap, then spin the phone slowly one full turn.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Phone sideways (top pointing to your left)", isOn: $sideways)
                    Text("Friend talks from the side you tap, 10 s each. (Listening stops by itself during a test.)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(["left", "front", "right"], id: \.self) { side in
                            Button(side.capitalized) { m.recordDirection(side, sideways: sideways) }
                                .buttonStyle(.bordered).disabled(m.dirBusy)
                        }
                    }
                    if !m.dirStatus.isEmpty { mono(m.dirStatus) }
                }

                box("Recording + log") {
                    Button("Record 20 s") { m.record() }.disabled(!m.running)
                    if !m.recordText.isEmpty { mono(m.recordText) }
                    mono("log: \(m.logName.isEmpty ? "-" : m.logName)")
                }
            }.padding()
        }
    }

    func box<V: View>(_ t: String, @ViewBuilder _ c: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(t).font(.headline); c() }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    func mono(_ s: String) -> some View { Text(s).font(.system(.footnote, design: .monospaced)) }
}

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
                ctx.stroke(p, with: .color(slotColors[s]), lineWidth: 2)
            }
        }
    }
}
