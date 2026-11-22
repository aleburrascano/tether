# Tether: working notes (app folder is still HearProbe)

This is the running lab notebook, not documentation: see README.md for how the app works today. Defaults quoted below are from the time of each note (current: delay 0.6 s, boost +4 dB, interrupter subtraction off).

**Goal:** sit anywhere with your phone on the table and AirPods in. The app shows the people talking, you tap one, and you hear only them, in near real time (under ~1 s).
**Hardware:** iPhone 13 Pro + AirPods/headphones. No camera, no phone next to each person, no voice-sample step.

## How it works today (ios/HearProbe)
mic -> Sortformer (who is talking, 4 slots, on the phone) -> bubbles
tap -> clip built from that person's solo moments -> REAL-TSE voice filter (on the phone, 18 ms per 40 ms) -> boost + limiter -> headphones

## Works (measured)
- Filter runs on the phone; output matches the Mac to 37 dB.
- Gate open 93% when the model says the selected person talks; filtered audio ready 98-100% even at 0.1 s delay.
- Sound turns on and off by itself with headphones.

## Ruled out (measured, don't reopen without new hardware)
- Direction on iPhone 13 Pro: 360 ambisonics not supported (iOS said so); stereo timing cue = 0; left/right level swing ~1.4 dB < 1.9 dB noise.
- Boosting what the MODEL hears: no help at distance, likely made background become a bubble.

## Measuring
Every session logs `f80` lines (each 80 ms: per-person probabilities, mic level, filter in/out level, mute, selection).
`.venv/bin/python tools/report.py <log>` gives per-person level (~distance), and for the selected person how much is kept, how much of others leaks, and how often the mute cut them.

## Layer scrutiny 2026-11-22 (measured on the Mac with the two test memos; small samples, two voices)
- Voiceprints (CAM++ in FluidAudio, beta): same/different correct 88% at 0.5 s, 96.7% at 1 s (thr 0.40), 98.7% at 1.5 s, 99.6% at 3 s; ~30 ms each on the Mac. A raw two-voice mix matches neither person.
- Voice filter is level-biased: target 7 dB quieter than the interrupter -> output matches target in 56% of 1.5 s windows; same voices at equal loudness -> 90%. Clip choice made no difference (5 clean clips: 56-59%).
- Subtracting the interrupter first (2nd filter pass): 56% -> 74%.
- Speaker model was used with NO post-processing; NVIDIA's CallHome-tuned values: onset 0.641, offset 0.561, pad_onset 0.229 s, pad_offset 0.079 s, min_on 0.511 s, min_off 0.296 s. FluidAudio notes v2 handles crowded overlap better than v2.1 (ours).
- Mute replay on 13 sessions: peeps 45 -> 5 with smoothing; others let through 8.6% of their solo time (was 0%).

## Rework built 2026-11-22 (each on a Debug switch; logs say which were on)
smoothed mute (NVIDIA thresholds for others, 0.5/0.3 hysteresis + 0.24 s early start for the person) | voiceprint-checked clips (saved as clip_*.wav) | subtract the most recent other talker (auto-off if the phone can't keep up) | speaker model v2 switch | quality meter every 1.5 s (played audio vs person) | Mark button -> saves last 10 s in+out.

## Open issues, in order (each needs a measured pass test before moving on)
1. **Overlap is hit or miss.** Likely cause: the label-based mute cuts the person when the speaker model mislabels them (friend session: muted 2418 of 2514 "someone else" moments).
   Fix: voiceprint check on the filter output instead of label mutes; voiceprint-check clip pieces.
   Pass test: recorded overlap scene, the person audible in >= 90% of their overlap time across 3 runs.
2. **Faint voices.** Listening boost + limiter added (default +12 dB). Pass test: users pick a default that is loud enough without distortion.
3. ~~UI design~~ DONE 2026-11-21: ring around the phone, fixed spots (1 top, 2 right, 3 bottom, 4 left), dark theme, boost + Start/Stop card.
4. **Who is who.** Last few words per bubble (on-device captions) + rename.
5. Background noise getting a bubble; anyone taking over a bubble (voiceprints, same as 1).
