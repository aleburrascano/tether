import Foundation

/// Who is actually behind each slot of the speaker model, judged by voiceprint.
///
/// The speaker model hands out four slots and is easily fooled by similar voices: two people who sound
/// alike get one slot, and anyone can take over a slot. This layer listens to what each slot says when it
/// talks alone, voiceprints the latest ~1.5 s, and keeps its own list of people:
///   - a slot's speech is compared against everyone known ("closest, and by how much"), not one fixed line;
///   - each person keeps the print they started with (anchor); only sure matches that still agree with it
///     are added, so nobody drifts into someone else;
///   - a slot whose speech keeps scoring low against its person, and agrees with itself, is a new person
///     sharing that slot; a new slot whose speech matches a known person is that same person again;
///   - rooms change the scores a lot (close and clean ~0.7, across a room ~0.4), so thresholds follow how each
///     person usually scores here.
/// Ported from Tether's Rust tracker (2026-11-22), made more cautious about creating people.
final class People {
    struct Person {
        let id: Int
        var anchor: [Float]
        var sum: [Float]
        var n: Float
        var print: [Float]
        var typical: Float = 0.46       // usual score against own print in this room
        var seen = 0
        var slot: Int                   // slot last heard on
        var frames = 0                  // solo frames attributed (for the clip builder)
    }

    private let lock = NSLock()
    private var persons: [Person] = []
    private var slotPerson = [Int?](repeating: nil, count: 4)
    private var owner: [Int: Int] = [:]                     // frame -> person id, for frames a print was made from
    private var cand: (embs: [[Float]], scores: [Float], newest: Int, slot: Int)? = nil
    private var lastDone = [Int](repeating: -100, count: 4)
    private var thread: Thread?
    private var running = false
    private var events: [[String: Any]] = []
    private(set) var text = ""

    // thresholds on the clean-room scale (a person's scores are lifted by their room shift before comparing)
    private let tMatch: Float = 0.42, tWeak: Float = 0.52, tLearn: Float = 0.55, tAnchor: Float = 0.40, margin: Float = 0.05
    private let maxPeople = 6

    func drainEvents() -> [[String: Any]] { lock.withLock { let e = events; events = []; return e } }

    func start(voices: Voices, extractor: Extractor) {
        lock.withLock { persons = []; slotPerson = .init(repeating: nil, count: 4); owner = [:]; cand = nil; lastDone = .init(repeating: -100, count: 4); text = "" }
        running = true
        let t = Thread { [weak self, weak voices, weak extractor] in
            while let s = self, s.running, let v = voices, let x = extractor {
                if Tuning.personCheck && Voiceprint.shared.ready { s.pass(v, x) }
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        t.qualityOfService = .utility
        t.start(); thread = t
    }
    func stop() { running = false }

    /// The person currently behind a slot, if decided.
    func current(slot: Int) -> Int? { lock.withLock { slotPerson[slot] } }
    var slotsNow: [Int] { lock.withLock { slotPerson.map { $0 ?? -1 } } }

    /// Everyone known: (person, the slot they were last heard on, whether that slot is theirs right now).
    func list() -> [(id: Int, slot: Int, mine: Bool)] {
        lock.withLock { persons.map { ($0.id, $0.slot, slotPerson[$0.slot] == $0.id) } }
    }

    /// For the clip builder: of a slot's solo frames, the ones known to be this person. Falls back to all of
    /// them until enough (2 s) have been attributed.
    func framesOf(person id: Int, among frames: [(Int, Float)]) -> [(Int, Float)] {
        lock.withLock {
            let mine = frames.filter { owner[$0.0] == id }
            return mine.count >= 25 ? mine : frames.filter { owner[$0.0] == nil || owner[$0.0] == id }
        }
    }

    // MARK: the pass (own thread)
    private func pass(_ voices: Voices, _ x: Extractor) {
        let fLen = 1280
        let latest = voices.latestFinal
        for s in 0..<4 {
            let recent = voices.soloFrames(slot: s).map { $0.0 }.filter { $0 > latest - 50 && ($0 + 1) * fLen <= x.histW }
            guard recent.count >= 12, let newest = recent.last, newest >= lastDone[s] + 6 else { continue }
            lastDone[s] = newest
            let used = Array(recent.suffix(19))                                   // ~1.5 s
            var audio: [Float] = []; audio.reserveCapacity(used.count * fLen)
            for f in used { for i in 0..<fLen { audio.append(x.hist[(f * fLen + i) & (x.histSize - 1)]) } }
            guard let e = Voiceprint.shared.embed(audio) else { continue }
            lock.withLock { decide(slot: s, emb: e, frames: used, newest: newest) }
        }
    }

    private func shift(_ p: Person) -> Float { max(-0.22, min(0, p.typical - 0.68)) }

    /// caller holds lock
    private func decide(slot s: Int, emb e: [Float], frames: [Int], newest: Int) {
        let raw = persons.map { Voiceprint.cos($0.print, e) }
        let scores = zip(raw, persons).map { $0 - shift($1) }
        var best = scores.indices.max { scores[$0] < scores[$1] }
        // too close to call between two people: stay with the one already on this slot
        if let b = best, let cur = slotPerson[s], let ci = persons.firstIndex(where: { $0.id == cur }), ci != b, scores[ci] >= scores[b] - margin, scores[ci] >= tMatch { best = ci }
        let top = best.map { scores[$0] } ?? -1
        var who: Int? = nil

        if let b = best, top >= tMatch {
            who = persons[b].id
            persons[b].typical += (raw[b] > persons[b].typical ? 0.35 : 0.03) * (raw[b] - persons[b].typical)
            persons[b].seen += 1
            if top >= tWeak {
                cand = nil
                let runner = scores.indices.filter { $0 != b }.map { scores[$0] }.max() ?? -1
                if top >= tLearn && top - runner >= margin && Voiceprint.cos(persons[b].anchor, e) >= tAnchor { learn(b, e) }
            } else if persons[b].seen >= 4, let id = unexplained(slot: s, e, top, newest, slotHasPerson: true) {
                who = id                                         // keeps scoring low: someone else on this slot
            }
        } else if let id = unexplained(slot: s, e, top, newest, slotHasPerson: slotPerson[s] != nil) {
            who = id
        }

        guard let id = who, let i = persons.firstIndex(where: { $0.id == id }) else { return }   // undecided: leave the slot as it was
        if slotPerson[s] != id {
            events.append(["type": "person_slot", "slot": s, "person": id, "score": Double((top * 100).rounded() / 100)])
            slotPerson[s] = id
        }
        persons[i].slot = s
        persons[i].frames += frames.count
        for f in frames { owner[f] = id }
        if owner.count > 4000 { let cut = newest - 2500; owner = owner.filter { $0.key >= cut } }
        text = (0..<4).map { k in slotPerson[k].map { "s\(k + 1)=v\($0 + 1)" } ?? "s\(k + 1)=-" }.joined(separator: " ") + String(format: "  last %.2f", top)
    }

    private func learn(_ i: Int, _ e: [Float]) {
        if persons[i].n >= 40 { persons[i].sum = persons[i].sum.map { $0 * (1 - 1 / 40) } } else { persons[i].n += 1 }
        persons[i].sum = zip(persons[i].sum, e).map { $0 + $1 }
        persons[i].print = Voiceprint.mean([persons[i].sum]) ?? persons[i].print
    }

    /// Speech nobody explains well. A new slot with a voice that matches nobody is a new person at once (the
    /// speaker model and the voiceprint agree). On a slot that already has a person it takes a few seconds in a row.
    private func unexplained(slot s: Int, _ e: [Float], _ best: Float, _ newest: Int, slotHasPerson: Bool) -> Int? {
        guard persons.count < maxPeople else { return nil }
        if !slotHasPerson && best < tMatch { return born([e], slot: s, why: "new slot, matches nobody") }
        // In echoey rooms the same person scores 0.4-0.45 against their own print, which looked like
        // "someone else on this slot" and made phantom voices (session 2026-11-22 07:02). Until that is
        // calibrated on real rooms, a slot that has a person keeps that person.
        if slotHasPerson { return nil }
        if let c = cand, c.slot != s || newest - c.newest > 40 || Voiceprint.cos(Voiceprint.mean(c.embs) ?? e, e) < 0.40 { cand = nil }
        if cand == nil { cand = ([], [], Int.min / 2, s) }
        if newest - cand!.newest >= 12 { cand!.embs.append(e); cand!.scores.append(best); cand!.newest = newest }
        let c = cand!
        let avg = c.scores.reduce(0, +) / Float(max(1, c.scores.count))
        let clearlyNew = c.scores.allSatisfy { $0 < tMatch - 0.10 }
        guard (c.embs.count >= 2 && clearlyNew) || (c.embs.count >= 3 && avg < tWeak - 0.04) else { return nil }
        cand = nil
        return born(c.embs, slot: s, why: clearlyNew ? "matches nobody" : "keeps scoring low on a shared slot")
    }

    private func born(_ embs: [[Float]], slot s: Int, why: String) -> Int? {
        guard let anchor = Voiceprint.mean(embs) else { return nil }
        let id = (persons.map { $0.id }.max() ?? -1) + 1
        var sum = [Float](repeating: 0, count: anchor.count)
        for e in embs { sum = zip(sum, e).map { $0 + $1 } }
        persons.append(Person(id: id, anchor: anchor, sum: sum, n: Float(embs.count), print: anchor, slot: s))
        events.append(["type": "person_new", "person": id, "slot": s, "why": why])
        return id
    }
}
