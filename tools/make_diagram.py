"""Draws docs/architecture.svg (the README's diagram). Icons are Lucide (ISC licence) paths, 24x24 grid."""
import sys
W, H = 1280, 640
BG, CARD, LINE, TEXT, SUB, DIM = "#0C0C10", "#15151B", "#2A2A34", "#F4F4F5", "#A1A1AA", "#6B6B76"
TEAL, CORAL, BLUE, AMBER, VIOLET = "#3FD8C8", "#E9785B", "#5AA9FF", "#F2C14E", "#B6A2F5"
FONT = "font-family=\"-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif\""
ICON = {
 "mic": '<path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><path d="M12 19v3"/>',
 "lines": '<path d="M2 10v3"/><path d="M6 6v11"/><path d="M10 3v18"/><path d="M14 8v7"/><path d="M18 5v13"/><path d="M22 10v3"/>',
 "users": '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
 "scissors": '<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M8.12 8.12 12 12"/><path d="M20 4 8.12 15.88"/><path d="M14.8 14.8 20 20"/>',
 "target": '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
 "star": '<path d="M12 3l2.2 6.8L21 12l-6.8 2.2L12 21l-2.2-6.8L3 12l6.8-2.2z"/>',
 "mute": '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M22 9l-6 6"/><path d="M16 9l6 6"/>',
 "phones": '<path d="M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3"/>',
 "chat": '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
 "clock": '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
}
o = []
def icon(name, x, y, colour, size=26):
    s = size / 24
    o.append(f'<g transform="translate({x - size/2:.1f},{y - size/2:.1f}) scale({s:.3f})" fill="none" stroke="{colour}" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">{ICON[name]}</g>')
def text(x, y, s, size=15, colour=TEXT, weight=500, anchor="middle", spacing=0):
    o.append(f'<text x="{x}" y="{y}" {FONT} font-size="{size}" font-weight="{weight}" fill="{colour}" text-anchor="{anchor}" letter-spacing="{spacing}">{s}</text>')
def card(x, y, w, h, ic, colour, title, model, lines, hero=False):
    fill = "#2A1712" if hero else CARD
    stroke = CORAL if hero else LINE
    o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{fill}" stroke="{stroke}" stroke-width="{2 if hero else 1}"/>')
    o.append(f'<circle cx="{x + 32}" cy="{y + 36}" r="17" fill="{colour}" fill-opacity="0.13"/>')
    icon(ic, x + 32, y + 36, colour, 19)
    text(x + 58, y + (33 if model else 41), title, 14, TEXT, 600, "start")
    if model: text(x + 58, y + 50, model, 12, colour, 600, "start")
    for i, l in enumerate(lines): text(x + 18, y + 84 + i * 18, l, 12.5, SUB, 400, "start")
def arrow(pts, colour=DIM, dash=False, label=None, lx=0, ly=0):
    d = "M" + " L".join(f"{x},{y}" for x, y in pts)
    o.append(f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="1.8" stroke-linejoin="round" {"stroke-dasharray=\"5 5\"" if dash else ""} marker-end="url(#a{colour[1:]})"/>')
    if label: text(lx, ly, label, 11.5, SUB, 500)

o.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="How Tether works: microphone, who is talking, voices on screen, clip builder, voice filter, clean-up, smart mute, headphones">')
o.append("<defs>" + "".join(f'<marker id="a{c[1:]}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M1 1L9 5L1 9" fill="none" stroke="{c}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></marker>' for c in (DIM, TEAL, CORAL, VIOLET)) + "</defs>")
o.append(f'<rect width="{W}" height="{H}" rx="24" fill="{BG}"/>')
o.append(f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="24" fill="none" stroke="{LINE}"/>')
text(40, 52, "HOW TETHER WORKS", 12.5, DIM, 600, "start", 1.6)
text(W - 40, 52, "everything inside the frame runs on the iPhone", 12.5, DIM, 400, "end")

cw, ch, gap, x0, ym = 176, 132, 32, 40, 262
xs = [x0 + i * (cw + gap) for i in range(6)]
# on-device frame around the five processing steps (cards 1..4 and the two upper ones)
fx, fy = xs[1] - 16, 84
o.append(f'<rect x="{fx}" y="{fy}" width="{xs[4] + cw + 16 - fx}" height="{ym + ch + 62 - fy}" rx="22" fill="#FFFFFF" fill-opacity="0.018" stroke="{LINE}" stroke-dasharray="3 6"/>')

yt = 104
card(xs[1], yt, cw, ch - 12, "users", BLUE, "Voices on screen", "SwiftUI", ["One spot per person.", "Tap the one to hear."])
card(xs[2], yt, cw, ch - 12, "scissors", TEAL, "Clip builder", "CAM++ voiceprints", ["3 s of that person alone,", "each piece verified."])

card(xs[0], ym, cw, ch, "mic", TEXT, "Microphone", "", ["The phone on the table", "hears the whole room."])
card(xs[1], ym, cw, ch, "lines", TEAL, "Who is talking", "NVIDIA Sortformer", ["Tracks up to four voices,", "12 decisions a second."])
card(xs[2], ym, cw, ch, "target", CORAL, "Voice filter", "REAL-TSE", ["Lifts your person out", "of the mixture."], hero=True)
card(xs[3], ym, cw, ch, "star", TEAL, "Clean-up", "LocalVQE", ["Removes noise and echo,", "evens out loudness."])
card(xs[4], ym, cw, ch, "mute", AMBER, "Smart mute", "", ["Closes while anyone", "else is talking."])
card(xs[5], ym, cw, ch, "phones", TEXT, "Headphones", "", ["Only the voice", "you picked."])

mid = ym + ch / 2
for i in range(5):
    arrow([(xs[i] + cw + 5, mid), (xs[i + 1] - 6, mid)], CORAL if i in (1, 2) else DIM)
# who is talking -> voices on screen -> clip builder -> voice filter
arrow([(xs[1] + cw / 2, ym - 5), (xs[1] + cw / 2, yt + ch - 12 + 6)], TEAL)
arrow([(xs[1] + cw + 5, yt + 60), (xs[2] - 6, yt + 60)], TEAL, label="tap", lx=xs[1] + cw + gap / 2, ly=yt + 51)
arrow([(xs[2] + cw / 2, yt + ch - 12 + 5), (xs[2] + cw / 2, ym - 6)], TEAL)
# who spoke when -> smart mute
yb = ym + ch + 30
arrow([(xs[1] + cw / 2, ym + ch + 5), (xs[1] + cw / 2, yb), (xs[4] + cw / 2, yb), (xs[4] + cw / 2, ym + ch + 6)], DIM, label="who spoke when", lx=(xs[1] + xs[4] + cw) / 2, ly=yb - 8)

# bottom row: the head start, and the optional agent
by, bh = 498, 104
o.append(f'<rect x="{x0}" y="{by}" width="{580}" height="{bh}" rx="16" fill="{CARD}" stroke="{LINE}"/>')
o.append(f'<circle cx="{x0 + 40}" cy="{by + 52}" r="22" fill="{AMBER}" fill-opacity="0.13"/>'); icon("clock", x0 + 40, by + 52, AMBER, 23)
text(x0 + 78, by + 40, "A 0.6 second head start", 15, TEXT, 600, "start")
text(x0 + 78, by + 62, "Sound is played just after it is heard. In that gap the models decide", 12.5, SUB, 400, "start")
text(x0 + 78, by + 80, "who was talking and the filter finishes, so nothing reaches you unfiltered.", 12.5, SUB, 400, "start")
ax = x0 + 580 + 40
o.append(f'<rect x="{ax}" y="{by}" width="{W - 40 - ax}" height="{bh}" rx="16" fill="{CARD}" stroke="{VIOLET}" stroke-opacity="0.55" stroke-dasharray="5 5"/>')
o.append(f'<circle cx="{ax + 40}" cy="{by + 52}" r="22" fill="{VIOLET}" fill-opacity="0.13"/>'); icon("chat", ax + 40, by + 52, VIOLET, 23)
text(ax + 78, by + 40, "Listening agent", 15, TEXT, 600, "start"); text(ax + 196, by + 40, "optional", 12, VIOLET, 600, "start")
text(ax + 78, by + 62, "Follows the conversation, names each voice (Barista, Teacher)", 12.5, SUB, 400, "start")
text(ax + 78, by + 80, "and raises a card when someone says something you should not miss.", 12.5, SUB, 400, "start")
o.append("</svg>")
open(sys.argv[1], "w").write("\n".join(o))
