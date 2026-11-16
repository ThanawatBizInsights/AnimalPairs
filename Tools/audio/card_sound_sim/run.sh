#!/usr/bin/env bash
# Linux-only simulation: drives the real AudioManager.swift against a working
# AVAudioPlayer stand-in (AVFoundation.swift here) and real bundled WAVs, with
# thousands of card flips for all ten animals. Run from the repository root
# after `swift build` in Packages/AnimalPairsKit. Not part of the app.
set -euo pipefail
ROOT=$(pwd); OUT=$(mktemp -d); cd Tools/audio/card_sound_sim
swiftc -emit-module -emit-library -module-name AVFoundation -parse-as-library AVFoundation.swift -o "$OUT/libAVFoundation.so" -emit-module-path "$OUT/AVFoundation.swiftmodule"
M=$(dirname "$(find "$ROOT/Packages/AnimalPairsKit/.build" -name AnimalPairsCore.swiftmodule -path '*Modules*' | head -1)")
sed "s#/work/#$ROOT/#" main.swift > "$OUT/main.swift"
swiftc -swift-version 5 -I "$OUT" -L "$OUT" -lAVFoundation -I "$M" "$ROOT/AnimalPairs/Audio/AudioManager.swift" "$OUT/main.swift" \
  $(find "$(dirname "$M")" -path '*AnimalPairsCore.build/*.o') -o "$OUT/sim"
LD_LIBRARY_PATH="$OUT" "$OUT/sim"
