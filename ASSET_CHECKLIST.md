# Asset checklist

Status of every artwork slot in `AnimalPairs/Resources/ArtworkManifest.json` (manifest `2026.11.2`) and other shipped media. **No development placeholders remain:** all 60 animal pictures are supplied artwork. `ManifestTests.testNoDevelopmentPlaceholdersRemain` and the backend's production publish check fail if a placeholder ever comes back.

## Animal pictures (60 — 10 animals × 6 poses)

`signature` is each animal's default card and is free; the other five poses are part of **Full Game Unlock**. Image sets in `AnimalPairs/Assets.xcassets/Artwork/` are named `<animal>_<pose>`; asset IDs (used by saved rounds) are `<animal>.<pose>`. Sources, with the original supplied filenames, are in `Design/Reference/Supplied/` (`POSES_SOURCES.md`).

| Animal | signature (free) | play | nap | wave | stretch | celebrate | Look-alike poses (never dealt together in Exact Pose) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Momo (puppy) | `momo_signature` | `momo_play` | `momo_nap` | `momo_wave` | `momo_stretch` | `momo_celebrate` | signature ≈ wave ≈ celebrate; play ≈ stretch |
| Iris (kitten) | `iris_signature` | `iris_play` | `iris_nap` | `iris_wave` | `iris_stretch` | `iris_celebrate` | signature ≈ wave |
| Nori (elephant) | `nori_signature` | `nori_play` | `nori_nap` | `nori_wave` | `nori_stretch` | `nori_celebrate` | signature ≈ wave ≈ celebrate ≈ play |
| Sprout (dinosaur) | `sprout_signature` | `sprout_play` | `sprout_nap` | `sprout_wave` | `sprout_stretch` | `sprout_celebrate` | signature ≈ wave; play ≈ celebrate |
| Mochi (bunny) | `mochi_signature` | `mochi_play` | `mochi_nap` | `mochi_wave` | `mochi_stretch` | `mochi_celebrate` | signature ≈ wave; play ≈ celebrate |
| Sunny (duckling) | `sunny_signature` | `sunny_play` | `sunny_nap` | `sunny_wave` | `sunny_stretch` | `sunny_celebrate` | signature ≈ wave ≈ stretch; play ≈ celebrate |
| Maple (bear cub) | `maple_signature` | `maple_play` | `maple_nap` | `maple_wave` | `maple_stretch` | `maple_celebrate` | signature ≈ wave ≈ celebrate |
| Clover (turtle) | `clover_signature` | `clover_play` | `clover_nap` | `clover_wave` | `clover_stretch` | `clover_celebrate` | signature ≈ wave ≈ celebrate ≈ stretch |
| Rusty (red panda) | `rusty_signature` | `rusty_play` | `rusty_nap` | `rusty_wave` | `rusty_stretch` | `rusty_celebrate` | signature ≈ stretch; wave ≈ celebrate |
| Pebble (penguin) | `pebble_signature` | `pebble_play` | `pebble_nap` | `pebble_wave` | `pebble_stretch` | `pebble_celebrate` | signature ≈ wave ≈ stretch ≈ celebrate |

* All supplied: Play and Nap (21 files, one spare), Wave (10), Stretch (10), Celebrate (10). Nothing is missing.
* **Duplicate:** Rusty had two nap pictures. `rusty_nap` uses “Sleeping red panda cutout-11” (same 1254 px canvas as the others, face clearly visible); “Rusty's Cozy Red Panda Nap-6” is kept unused in `Design/Reference/Supplied/Alternates/`.
* Processing (`python3 Tools/artwork/build_artwork.py`): transparent background kept, only specks under 0.05 % of the body removed (Nori's water drops, Sunny's splash and Iris's yarn are kept), trimmed, centred on 1024 × 1024, and no pose fills more than 45 % of the card so compact poses (e.g. Rusty curled up) don't look bigger than tall ones. Never stretched, enlarged past its fit or cropped.
* The look-alike groups are a judgement call made from the pictures; adjust `lookalikePoseGroups` in the manifest if you see it differently. Art-director sign-off on the processed images is still welcome.

## Adding or replacing a picture

1. One PNG per pose, transparent background, at least 1024 × 1024 px, same style as the others.
2. Save it as `Design/Reference/Supplied/<animal>_<pose>.png`; add or update its manifest entry (`resourceName` `<animal>_<pose>`, increase `version` when the picture changes).
3. Run `python3 Tools/artwork/build_artwork.py` and `python3 Tools/localization/check_strings.py`, and write the English description `art.<animal>.<pose>` in `Localizable.xcstrings`.
4. Never mirror, recolour or redraw one illustration to make another pose. Both cards of a pair always use the same single file.

## Other media

| Item | Location | Status |
| --- | --- | --- |
| App icon (1024 px) | `AppIcon.appiconset` ← `Design/Reference/Supplied/ui_app_icon.png` | final art supplied. Delivered with white pre-rounded corners; `build_ui_graphics.py` fills them from the surrounding art (iPadOS applies its own mask). Sign-off pending — ideally request a square, unrounded master from the designer |
| “Animal Pairs” wordmark | `UI/brand_wordmark` ← `ui_wordmark.png` | final art supplied — background haze removed |
| Group illustration (all ten) | `UI/home_group_animals` ← `ui_group_animals.png` | final art supplied — used on Welcome and Home only, never as a card image |
| Trophy badge | `UI/results_trophy` ← `ui_trophy_badge.png` | final art supplied — localized “Well done!” is drawn on the ribbon by the app |
| Card back | `UI/card_back` ← `ui_card_back.webp` | final art supplied — used on every card; the board uses its 0.735 width:height ratio so it is never stretched |
| Floral corner accents | `UI/decor_corner_*` ← `ui_floral_corners.png` | final art supplied — split into four corners; used on Welcome, Home and Results, never on the game board |
| ElevenLabs batch 1 (8 core sounds) | `AnimalPairs/Resources/Sounds/` | **approved**, bundled |
| ElevenLabs batch 2 (11 interface & reward sounds) | `AnimalPairs/Resources/Sounds/` | **approved**, bundled; `star_earn`, `badge_reveal`, `new_best` unused (no stars, badges or best scores) |
| Reward sound revisions (`star_earn_v2`, `badge_reveal_v2`, `new_best_v2`, `try_again_v2`) | `Design/Audio/Review/` | **awaiting your review**; approving one replaces the bundled file of the same name |
| Music loops (4): playground, focus, celebration, meadow | `AnimalPairs/Resources/Music/*.m4a` + `music_tracks.json`; masters in `Design/Audio/Music/` | **bundled**, played as background music (Home, gameplay, results, Parents) |
| Animal clips, all 10 animals × greeting, curious, excited, calm (40) | `AnimalPairs/Resources/Sounds/Animals/<animal>_<variant>.m4a` + `animal_clips.json` | **bundled** (generated with ElevenLabs; masters, originals and every take in `Design/Audio/Animals/`); `mochi_excited` is 2.0 s, a little under the 3–5 s aim |
| Voice recordings | — | none (English only; the planned Thai lines were removed) |
| Opening video | `AnimalPairs/Resources/Video/opening_video.mp4` | **approved**, bundled (supplied by the user) |
| Synthesized tones (`flip`, `match`, `mismatch`, `complete`, `tap`, `hint_synth`) | `AnimalPairs/Resources/Sounds` ← `Tools/audio/build_sounds.py` | fallbacks only |
| Full sound list, prompts, credits and status | `Tools/audio/audio_manifest.json` | source of truth |
| Launch screen | Info.plist `UILaunchScreen` (ivory colour) | final (colour only) |
| App Store screenshots, preview video, marketing text | — | **missing** |
| Privacy policy and support pages (URLs) | build settings `AP_PRIVACY_POLICY_URL`, `AP_SUPPORT_URL` | **missing** — the Parents screen explains this until set |
