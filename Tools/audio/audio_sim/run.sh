#!/usr/bin/env bash
# Linux-only audio simulation (not part of the app). Compiles the app's real
# AudioManager.swift, MusicPlayer.swift, GameSession.swift and Localizer.swift against small
# stand-ins for AVFoundation and SwiftUI, then plays many rounds and Home taps
# with the bundled sounds and animal clips.
# Run from the repository root after `swift build` in Packages/AnimalPairsKit.
set -euo pipefail
ROOT=$(pwd); OUT=$(mktemp -d); HERE="$ROOT/Tools/audio/audio_sim"
for m in AVFoundation SwiftUI; do
  swiftc -emit-library -emit-module -module-name $m -parse-as-library "$HERE/$m.swift" \
    -o "$OUT/lib$m.so" -emit-module-path "$OUT/$m.swiftmodule"
done
# The toolchain's Observation runtime may not link here; observation is UI-only,
# so the simulation compiles a copy of GameSession without the macros.
sed -e '/^@Observable$/d' -e 's/@ObservationIgnored //' -e '/^import Observation$/d' \
  "$ROOT/AnimalPairs/Game/GameSession.swift" > "$OUT/GameSession.swift"
M=$(dirname "$(find "$ROOT/Packages/AnimalPairsKit/.build" -name AnimalPairsCore.swiftmodule -path '*Modules*' | head -1)")
swiftc -swift-version 5 -I "$OUT" -L "$OUT" -lAVFoundation -lSwiftUI -I "$M" \
  "$ROOT/AnimalPairs/Audio/AudioManager.swift" "$ROOT/AnimalPairs/Audio/MusicPlayer.swift" "$OUT/GameSession.swift" \
  "$ROOT/AnimalPairs/Localization/Localizer.swift" "$HERE/main.swift" \
  $(find "$(dirname "$M")" -path '*AnimalPairsCore.build/*.o') -o "$OUT/sim"
LD_LIBRARY_PATH="$OUT" "$OUT/sim" "$ROOT"
