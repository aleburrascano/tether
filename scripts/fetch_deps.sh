#!/bin/sh
# Fetch the parts of Tether that are not in git.
set -e
cd "$(dirname "$0")/.."

# 1) FluidAudio (speaker model, voiceprints, noise remover): pinned git submodule
git submodule update --init vendor/FluidAudio

# 2) ONNX Runtime for iOS (runs the voice filter). The CocoaPods/SPM channels were dead in Nov 2026;
#    Microsoft's NuGet package (signed by Microsoft) carries the iOS xcframework.
if [ ! -d vendor/ort/onnxruntime.xcframework ]; then
  mkdir -p vendor/ort && cd vendor/ort
  curl -sL --fail -o ort.nupkg "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.32.0/microsoft.ml.onnxruntime.1.32.0.nupkg"
  unzip -oq ort.nupkg "runtimes/ios/native/onnxruntime.xcframework.zip"
  unzip -oq runtimes/ios/native/onnxruntime.xcframework.zip -d .
  rm -rf runtimes ort.nupkg
  cd ../..
fi

# 3) Voice filter model files (REAL-TSE causal, int8 ONNX) - NOT downloadable; copy them in by hand:
#    ios/HearProbe/Models/enroll.onnx  and  ios/HearProbe/Models/chunk_int8.onnx
for f in enroll.onnx chunk_int8.onnx; do
  [ -f "ios/HearProbe/Models/$f" ] || echo "MISSING: ios/HearProbe/Models/$f (copy it in by hand)"
done

# 4) Generate the Xcode project
command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen"; exit 1; }
cd ios && xcodegen generate
