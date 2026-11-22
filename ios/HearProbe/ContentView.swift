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
    static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)      // the agent
    static let green = Color(red: 0.20, green: 0.84, blue: 0.45)        // the voice you hear
    static let red = Color(red: 0.93, green: 0.33, blue: 0.31)          // a voice the app is still learning
    static let coral = Color(red: 0.910, green: 0.471, blue: 0.353)     // the mascot's colour: welcome and walkthrough
    static let peach = Color(red: 1.0, green: 0.847, blue: 0.773)
    static let ink = Color(red: 0.17, green: 0.11, blue: 0.19)          // dark plum, for text on white
    static let ease = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.32)
}

struct ContentView: View {
    @StateObject private var m = Model()
    @StateObject private var brain = BrainModel()
    @StateObject private var agent = Agent()
    @State private var showSettings = false
    @State private var history = [Float](repeating: 0, count: 44)
    @State private var ready: Set<Int> = []          // voices heard alone for long enough to be picked
    @State private var ticks = 0
    @AppStorage("tourDone") private var tourDone = false
    @State private var tourStep = UserDefaults.standard.integer(forKey: "tourStart")   // 0 = welcome, 1... = the walkthrough (the key is only for checking screens)
    @State private var marks: [String: CGRect] = [:]
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    /// Each voice sits a little off the row, so they look placed rather than lined up.
    private static let drop: [CGFloat] = [4, 22, 10, 26], shift: [CGFloat] = [-5, 6, -2, 7]

    private var touring: Bool { !tourDone && tourStep > 0 }

    var body: some View {
        ZStack {
            Look.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.frame(height: 44).opacity(touring ? 0 : 1)        // no buttons while the walkthrough runs
                stage.frame(maxHeight: .infinity)
                bottom.frame(height: 150).tourMark("bars")
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
            if touring {
                Tour(step: $tourStep, marks: marks) { withAnimation(Look.ease) { tourDone = true } }
            }
            if !tourDone && tourStep == 0 {
                Welcome(start: { withAnimation(Look.ease) { tourStep = 1 } }, skip: { withAnimation(Look.ease) { tourDone = true } })
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(TourMarks.self) { marks = $0 }
        .preferredColorScheme(!tourDone && tourStep == 0 ? .light : .dark)
        .onAppear { m.loadModel() }
        .onChange(of: tourDone) { _, done in if !done { tourStep = 0 } }
        .onReceive(tick) { _ in
            ticks += 1
            if touring {                                   // the walkthrough shows a pretend room
                history.removeFirst(); history.append(Float(0.35 + 0.3 * sin(Double(ticks) * 0.5) * sin(Double(ticks) * 0.13)))
                brain.step(heard: 0.55, dt: 0.1)
                return
            }
            // -60 dB and below = 0, -15 dB = 1 (what the level bars show)
            let v = m.running ? max(0, min(1, (m.level + 60) / 45)) : 0
            history.removeFirst(); history.append(v)
            brain.step(heard: heard(v), dt: 0.1)
            agent.tick(m)
            if ticks % 5 == 0 {                            // twice a second: which voices are ready to pick
                let now = Set(m.bubbles.filter { m.soloSeconds($0) >= Extractor.minSoloSec }.map { $0.id })
                if now != ready { withAnimation(Look.ease) { ready = now } }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(m: m).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    /// How much sound reaches the headphones, 0...1: the picked voice's moments; nothing when nobody is
    /// picked or without headphones.
    private func heard(_ room: Float) -> Float {
        guard m.running, !m.speakerWarning else { return 0 }
        guard let s = m.selected else { return 0 }                  // nobody picked: silence
        return (m.bubbles.first { $0.id == s }?.talking ?? false) ? room : room * 0.08
    }

    private var tone: Color { !m.running ? Look.text3 : m.speakerWarning ? Look.orange : (m.bubbles.contains { $0.talking } ? Look.green : Look.text2) }

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

    /// One voice as the screen shows it.
    private struct Shown: Identifiable { let id: Int; let talking: Bool; let state: VoiceState; let bubble: Model.Bubble?; var name = "" }

    /// Red: the app has not heard enough of this voice alone yet, so it cannot be picked.
    /// Grey: ready, tap it. Green: this is who you hear.
    private var shown: [Shown] {
        if touring {
            return [Shown(id: 0, talking: true, state: .on, bubble: nil, name: "Friend"), Shown(id: 1, talking: false, state: .ready, bubble: nil, name: "Barista"),
                    Shown(id: 2, talking: true, state: .learning, bubble: nil, name: "Speaker 3")]
        }
        return m.bubbles.map { b in
            let state: VoiceState = m.selected == b.id ? (m.filterActive ? .on : .starting) : (ready.contains(b.id) ? .ready : .learning)
            // "Speaker 2" until the agent works out who they are; two voices with the same name keep their number
            var name = "Speaker \(b.id + 1)"
            if let label = agent.labels[b.id] {
                name = m.bubbles.contains { $0.id != b.id && agent.labels[$0.id] == label } ? "\(label) \(b.id + 1)" : label
            }
            return Shown(id: b.id, talking: b.talking, state: state, bubble: b, name: name)
        }
    }

    // The voices on top, the brain in the middle; the voice you hear is joined to the brain by a line of sound.
    private var stage: some View {
        GeometryReader { geo in
            let voices = shown
            let n = max(1, voices.count)
            let size: CGFloat = n <= 3 ? 62 : 54
            let brainSide = min(geo.size.width, geo.size.height - 138)
            let brainMid = CGPoint(x: geo.size.width / 2, y: 138 + (geo.size.height - 138) / 2)
            let place = { (i: Int, id: Int) -> CGPoint in
                CGPoint(x: min(geo.size.width - size * 0.72, max(size * 0.72, geo.size.width * (CGFloat(i) + 0.5) / CGFloat(n) + Self.shift[id & 3])), y: 22 + size / 2 + Self.drop[id & 3])
            }
            ZStack {
                Color.clear.frame(width: geo.size.width, height: 150).tourMark("voices").position(x: geo.size.width / 2, y: 75).allowsHitTesting(false)
                ForEach(Array(voices.enumerated()), id: \.element.id) { i, v in
                    if v.state == .on || v.state == .starting {
                        SoundLine(from: place(i, v.id), to: CGPoint(x: brainMid.x - brainSide * 0.04, y: brainMid.y + brainSide * 0.04),
                                  lively: v.talking && v.state == .on ? 1 : 0.25, seed: Double(v.id))
                    }
                }
                Brain3DView(brain: brain).frame(width: brainSide, height: brainSide).position(brainMid)
                    .opacity(m.running || touring ? 1 : 0.55)
                    .accessibilityLabel("Illustration of a brain that brightens with the sound you hear")
                Color.clear.frame(width: brainSide * 0.9, height: brainSide * 0.66).tourMark("brain").position(brainMid).allowsHitTesting(false)
                ForEach(Array(voices.enumerated()), id: \.element.id) { i, v in
                    ZStack {
                        WavyBlob(colour: v.state.colour, size: size, level: v.talking ? 1 : 0, seed: Double(v.id) * 1.7)
                            .frame(width: size * 2.3, height: size * 2.3)
                        Text(v.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(v.state == .on ? Look.green : Look.text)
                            .lineLimit(1).fixedSize().offset(y: size / 2 + 22)
                            .id(v.name).transition(.opacity)
                    }
                    .animation(Look.ease, value: v.name)
                    .opacity(v.state == .learning ? 0.8 : 1)
                    .contentShape(Circle())
                    .onTapGesture {
                        guard let b = v.bubble else { return }
                        if v.state == .learning {                                   // not ready: say no, do nothing
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            return
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(Look.ease) { m.tap(b) }
                    }
                    .position(place(i, v.id))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("\(v.name), \(v.state.spoken)" + (v.talking ? ", talking" : ""))
                    .accessibilityAddTraits(v.state == .learning ? [] : .isButton)
                }
            }
            .animation(Look.ease, value: voices.map { $0.id })
        }
    }

    /// The sound of the room as bars. Anything you must know (still loading, no headphones, an error)
    /// is written over them in a few big words; the agent's question sits on top of everything.
    private var bottom: some View {
        ZStack {
            Levels(history: history, tone: touring ? Look.text2 : tone).padding(.vertical, 6).opacity(touring ? 1 : (m.running ? (notice == nil ? 1 : 0.25) : 0.3))
            if let notice, agent.alert == nil, !touring {
                VStack(spacing: 4) {
                    Text(notice.0).font(.system(size: 28, weight: .semibold)).tracking(-0.5).foregroundStyle(m.speakerWarning && m.running ? Look.orange : Look.text)
                    if !notice.1.isEmpty { Text(notice.1).font(.system(size: 15)).foregroundStyle(Look.text2).multilineTextAlignment(.center).lineLimit(2) }
                }
            }
            if touring && tourStep >= 4 {
                AgentCard(alert: Agent.Alert(who: "Barista", summary: "Order 42 is ready", voice: nil)) { _ in }.allowsHitTesting(false)
            }
            // the question is only asked about a voice you can actually pick (grey), never a red one
            if let a = agent.alert, m.running, !touring, let av = a.voice, ready.contains(av), m.selected != av {
                AgentCard(alert: a) { yes in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if yes, let v = a.voice, m.selected != v, ready.contains(v), let b = m.bubbles.first(where: { $0.id == v }) { m.tap(b) }
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

enum VoiceState {
    case learning, ready, starting, on
    var colour: Color { switch self { case .learning: return Look.red; case .ready, .starting: return Color(white: 0.56); case .on: return Look.green } }
    var spoken: String { switch self { case .learning: return "still learning, not ready"; case .ready: return "ready to pick"; case .starting: return "starting"; case .on: return "this is who you hear" } }
}

// MARK: - Welcome and walkthrough

/// Where things are on the screen, so the walkthrough can point at them.
struct TourMarks: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
extension View {
    func tourMark(_ name: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: TourMarks.self, value: [name: g.frame(in: .global)]) })
    }
}

/// The first thing you see. White page: the name up top, rings of sound spreading across it, and the
/// mascot peeking up from behind the panel that holds the one button.
struct Welcome: View {
    let start: () -> Void, skip: () -> Void
    @State private var up = false
    var body: some View {
        GeometryReader { geo in
            let panel: CGFloat = 176
            // the whole ear, centred in the open space between the words and the button panel
            let top: CGFloat = 196, room = geo.size.height - panel - top
            let earH = min(room * 0.86, geo.size.width * 0.74 * 1.305), earW = earH / 1.305
            let earMid = CGPoint(x: geo.size.width / 2, y: top + room / 2)
            ZStack(alignment: .topLeading) {
                Color.white.ignoresSafeArea()
                // waves of sound coming in to the ear from all around
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    Canvas { ctx, size in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        for k in 0..<4 {
                            let phase = (t * 0.22 + Double(k) / 4).truncatingRemainder(dividingBy: 1)
                            let r = earH * (0.46 + 0.62 * (1 - phase))                   // each ring shrinks towards the ear
                            ctx.stroke(Path(ellipseIn: CGRect(x: earMid.x - r, y: earMid.y - r, width: 2 * r, height: 2 * r)),
                                       with: .color(Look.peach.opacity(0.9 * sin(phase * .pi))), lineWidth: 9)
                        }
                    }
                }
                .ignoresSafeArea().accessibilityHidden(true)

                Image("MascotCut").resizable().scaledToFit().frame(width: earW, height: earH)
                    .position(x: earMid.x, y: earMid.y + (up ? -5 : 5))
                    .accessibilityLabel("Tether's mascot, a smiling ear")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tether").font(.system(size: 56, weight: .heavy, design: .rounded)).tracking(-1.5).foregroundStyle(Look.ink)
                    Text("Hear who\nyou want.").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.5).foregroundStyle(Look.coral)
                        .lineSpacing(-2)
                }
                .padding(.horizontal, 28).padding(.top, 28)

                // the panel the mascot peeks over
                VStack(spacing: 4) {
                    Button(action: start) {
                        Text("Show me how").font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 58).background(Look.coral, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(Press())
                    Button(action: skip) {
                        Text("Skip").font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity).frame(height: 48)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 28)
                .frame(width: geo.size.width, height: panel, alignment: .top)
                .background(Look.ink.clipShape(UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34, style: .continuous)).ignoresSafeArea(edges: .bottom))
                .position(x: geo.size.width / 2, y: geo.size.height - panel / 2)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { up = true } }
    }
}

/// The walkthrough: the screen dims, one part stays lit, and the mascot says what it is.
/// Drawn over the whole screen (under the notch too); places are in screen coordinates.
struct Tour: View {
    @Binding var step: Int
    let marks: [String: CGRect]
    let done: () -> Void

    private static let steps: [(mark: String, title: String, text: String)] = [
        ("voices", "Voices show up here", "Red is still learning. Grey is ready, tap it. Green is who you hear."),
        ("brain", "Your brain on sound", "The more sound reaches you, the harder your brain works."),
        ("bars", "The room's sound", "Big bars mean a loud room."),
        ("bars", "I'll tell you", "If someone calls you, I ask if you want to hear them."),
    ]

    var body: some View {
        let i = min(max(step, 1), Tour.steps.count) - 1
        let s = Tour.steps[i]
        let last = i == Tour.steps.count - 1
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let mark = marks[s.mark] ?? CGRect(x: 20, y: geo.size.height / 3, width: geo.size.width - 40, height: 120)
            // the lit part: the marked place, a little bigger, kept inside the screen's side margins
            let hole = mark.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -8, dy: -8)
                .intersection(CGRect(x: 8, y: 0, width: geo.size.width - 16, height: geo.size.height))
            let safe = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets ?? .zero
            let roomAbove = hole.minY - safe.top, roomBelow = geo.size.height - safe.bottom - hole.maxY
            let below = roomAbove < 200 || (hole.midY < geo.size.height * 0.45 && roomBelow >= 200)
            ZStack {
                Canvas { ctx, size in
                    var shade = Path(CGRect(origin: .zero, size: size))
                    shade.addRoundedRect(in: hole, cornerSize: CGSize(width: 24, height: 24), style: .continuous)
                    ctx.fill(shade, with: .color(.black.opacity(0.8)), style: FillStyle(eoFill: true))
                    ctx.stroke(Path(roundedRect: hole.insetBy(dx: 1, dy: 1), cornerRadius: 23, style: .continuous), with: .color(Look.coral), lineWidth: 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { next(last) }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Image("Mascot").resizable().scaledToFit().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title).font(.system(size: 24, weight: .semibold, design: .rounded)).tracking(-0.4).foregroundStyle(Look.text)
                            Text(s.text).font(.system(size: 17)).foregroundStyle(Look.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        ForEach(0..<Tour.steps.count, id: \.self) { k in
                            Capsule().fill(k == i ? Look.coral : Color.white.opacity(0.2)).frame(width: k == i ? 18 : 6, height: 6)
                        }
                        Spacer()
                        if !last { Button("Skip") { done() }.font(.system(size: 16, weight: .medium)).foregroundStyle(Look.text2).frame(height: 44).padding(.trailing, 8) }
                        Button { next(last) } label: {
                            Text(last ? "Got it" : "Next").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                                .padding(.horizontal, 24).frame(height: 44).background(Look.coral, in: Capsule())
                        }
                        .buttonStyle(Press())
                    }
                }
                .padding(18)
                .background(Look.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Look.line, lineWidth: 1))
                .padding(.horizontal, 16)
                // exactly 14 points from the lit part, on whichever side has room
                .padding(below ? .top : .bottom, below ? hole.maxY + 14 : geo.size.height - hole.minY + 14)
                .frame(width: geo.size.width, height: geo.size.height, alignment: below ? .top : .bottom)
                .id(i).transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
    }

    private func next(_ last: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if last { done() } else { withAnimation(Look.ease) { step += 1 } }
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
                    context.stroke(path, with: .color(Look.green.opacity(0.85 - 0.25 * k)), style: StrokeStyle(lineWidth: 2.4 - 0.6 * k, lineCap: .round, lineJoin: .round))
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
                Section {
                    Button("Show the walkthrough again") { UserDefaults.standard.set(false, forKey: "tourDone"); dismiss() }
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
