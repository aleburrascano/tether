import SwiftUI

struct ContentView: View {
    @StateObject private var m = Model()

    var body: some View {
        TabView {
            MapScreen(m: m).tabItem { Label("Map", systemImage: "dot.radiowaves.left.and.right") }
            DebugScreen(m: m).tabItem { Label("Debug", systemImage: "waveform.path.ecg") }
        }
    }
}

// MARK: - Map

struct MapScreen: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(spacing: 14) {
            Text(headline).font(.headline).multilineTextAlignment(.center).frame(minHeight: 44)

            RoomMap(people: m.people, selected: m.selected) { m.tap($0) }
                .frame(maxWidth: .infinity).aspectRatio(1.6, contentMode: .fit)

            Text((m.sideways ? "Phone flat, sideways, top pointing to your left." : "Phone flat on the table, top pointing away from you.") + " Left/right only: someone behind you shows up in front. Distance is a guess from loudness. Calibrate on the Debug tab first.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)

            Toggle("Hear in AirPods", isOn: Binding(get: { m.listening }, set: { m.setListening($0) }))
                .disabled(!m.running)
            Toggle("Mute everyone except who I tapped", isOn: Binding(get: { m.onlySelected }, set: { m.setOnlySelected($0) }))
                .disabled(!m.running)

            Button(m.running ? "Stop" : "Start listening") { m.toggle() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if !m.error.isEmpty { Text(m.error).foregroundStyle(.red).font(.footnote) }
        }
        .padding()
    }

    var headline: String {
        if !m.running { return "Tap Start, then let people talk." }
        if !m.stereo { return "Only 1 mic channel - this phone setup cannot tell direction. See Debug." }
        if m.people.isEmpty { return "Listening... people appear as they talk." }
        if let s = m.selected { return "Listening to Person \(s). Tap them again to hear everyone." }
        return "Tap a person to hear only them."
    }
}

struct RoomMap: View {
    let people: [Person]
    let selected: Int?
    let onTap: (Person) -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let me = CGPoint(x: w / 2, y: h - 18)
            let R = min(w / 2, h - 18) - 26
            ZStack {
                // half-circle room in front of you, with distance rings
                ForEach([0.33, 0.66, 1.0], id: \.self) { f in
                    HalfRing().stroke(.gray.opacity(0.25), lineWidth: 1)
                        .frame(width: 2 * R * f, height: R * f).position(x: me.x, y: me.y - R * f / 2)
                }
                Circle().fill(.primary).frame(width: 14).position(me)
                Text("you").font(.caption2).foregroundStyle(.secondary).position(x: me.x, y: me.y + 13)

                ForEach(people) { p in
                    let pos = point(p, me, R)
                    let sel = p.id == selected
                    Button { onTap(p) } label: {
                        ZStack {
                            if p.active { Circle().fill(color(p).opacity(0.25)).frame(width: 64) }
                            Circle().fill(sel ? Color.blue : color(p)).frame(width: 40)
                            if sel { Circle().stroke(.blue, lineWidth: 3).frame(width: 52) }
                            Text("\(p.id)").font(.headline).foregroundStyle(.white)
                        }
                        .opacity(selected == nil || sel ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .position(pos)
                    .animation(.easeOut(duration: 0.25), value: p.angle)
                }
            }
        }
    }

    func point(_ p: Person, _ me: CGPoint, _ R: CGFloat) -> CGPoint {
        // louder = closer: -25 dBFS -> near, -65 dBFS -> far edge
        let f = CGFloat(max(0.18, min(1, (-25 - p.db) / 40 * 0.82 + 0.18)))
        let a = CGFloat(p.angle) * .pi / 180
        return CGPoint(x: me.x + R * f * sin(a), y: me.y - R * f * cos(a))
    }

    func color(_ p: Person) -> Color { [.orange, .green, .purple, .pink, .teal, .brown][(p.id - 1) % 6] }
}

struct HalfRing: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY), radius: r.width / 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        return p
    }
}

// MARK: - Debug

struct DebugScreen: View {
    @ObservedObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Debug").font(.largeTitle.bold())
                box("Route") { mono(m.route.isEmpty ? "not started" : m.route) }

                box("Calibrate direction (do this first)") {
                    Toggle("Phone sideways (top pointing to your left)", isOn: Binding(get: { m.sideways }, set: { m.setSideways($0) }))
                    HStack {
                        Button("He's on my LEFT") { m.calibrate("left") }.buttonStyle(.bordered).disabled(!m.running || m.calibrating != nil)
                        Button("He's on my RIGHT") { m.calibrate("right") }.buttonStyle(.bordered).disabled(!m.running || m.calibrating != nil)
                    }
                    Text("Tap while he talks from that side; keep him talking ~5 s.").font(.caption).foregroundStyle(.secondary)
                    mono(m.calibText)
                    mono(String(format: "right-vs-left now: %+.1f dB", m.snap.ildNow))
                }

                box("Direction histogram (left ... right)") {
                    HStack(alignment: .bottom, spacing: 1) {
                        let t = max(m.snap.hist.reduce(0, +), 1e-15)
                        ForEach(0..<Engine.nBins, id: \.self) { b in
                            Rectangle().fill(.blue.opacity(0.7))
                                .frame(height: max(1, CGFloat(m.snap.hist[b] / t) * 300))
                        }
                    }.frame(height: 90, alignment: .bottom)
                    mono(String(format: "level L %.0f  R %.0f dB   R-L %+.1f dB   lag %+.2f ms", m.snap.levelL, m.snap.levelR, m.snap.ild, m.snap.lagMs))
                    mono(String(format: "frame %.0f dB  noise %.0f dB  speech %@", m.snap.frameDB, m.snap.noiseDB, m.snap.speech ? "yes" : "no"))
                    HStack {
                        Text(String(format: "full left/right at %.1f dB", abs(m.ildScale))).font(.caption)
                        Slider(value: Binding(get: { abs(m.ildScale) }, set: { m.ildScale = (m.ildScale < 0 ? -1 : 1) * $0 }), in: 0.5...20, step: 0.5)
                    }
                }

                box("People") {
                    if m.people.isEmpty { mono("none yet") }
                    ForEach(m.people) { p in
                        mono(String(format: "#%d  angle %+4.0f  %.0f dB  %@%@", p.id, p.angle, p.db, p.active ? "talking" : "quiet", p.id == m.selected ? "  SELECTED" : ""))
                    }
                    mono(String(format: "gate %.0f   share from selected direction %.2f", m.snap.gate, m.snap.selectedFrac))
                }

                box("Delay") {
                    Button("Measure delay") { m.measureDelay() }.disabled(!m.running)
                    Text("Hold one AirPod against the bottom of the phone, then tap.").font(.caption).foregroundStyle(.secondary)
                    mono(m.snap.delayMs.isNaN ? "not measured" : String(format: "loop %.0f ms (mic-to-ear is about this + ~10 ms)", m.snap.delayMs))
                    mono(String(format: "buffered %.0f ms   underruns %d", m.snap.bufferedMs, m.snap.underruns))
                }

                box("Recording + log") {
                    Button("Record 20 s of raw audio") { m.record() }.disabled(!m.running)
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
