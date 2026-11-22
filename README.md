# Tether

Sit anywhere with your phone on the table and AirPods in. The app shows the people talking around you; tap one and you hear only them, in near real time.

Everything runs on the iPhone (tested: iPhone 13 Pro, iPhone 14 Pro Max).

## How it works (layers)
1. **Audio in/out** - phone mic -> 0.3 s delay line -> boost + limiter -> headphones (AVAudioEngine).
2. **Who is talking** - NVIDIA Sortformer v2.1 streaming diarization via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML, Neural Engine), 4 people, 80 ms frames, smoothed with NVIDIA's tuned thresholds.
3. **Clip builder** - collects ~3 s of the tapped person talking alone; each piece checked with CAM++ voiceprints.
4. **Voice filter** - REAL-TSE causal target-speaker extraction (int8 ONNX, ONNX Runtime, CPU); optionally subtracts the loudest interrupter first.
5. **Clean-up** - LocalVQE noise + echo removal, automatic per-person loudness.
6. **Mute** - closes when someone else is clearly talking alone.

Measurements, findings and the open-issue list live in [PLAN.md](PLAN.md).

## Setup
```sh
git clone --recurse-submodules <this repo>
./scripts/fetch_deps.sh          # FluidAudio submodule, ONNX Runtime, xcodegen project
# copy enroll.onnx + chunk_int8.onnx into ios/HearProbe/Models/ (not in git)
open ios/HearProbe.xcodeproj     # set your own signing team in ios/project.yml first
```
Models (speaker model ~245 MB, voiceprints ~28 MB, noise remover ~18 MB) download on first launch.

## Tools
- `tools/report.py <debug.jsonl>` - per-person levels, how much the filter keeps / leaks, mute behaviour.
- `tools/gate_sim.py <logs...>` - replay logged sessions through mute rules.
- `tools/vpcal` - Swift CLI: voiceprint calibration and filter-output checks on the Mac.

## Privacy
Session recordings, debug logs and test voices are deliberately git-ignored. Do not commit audio of real people.
