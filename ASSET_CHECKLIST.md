# Asset checklist

Status of every artwork slot in `AnimalPairs/Resources/ArtworkManifest.json` (manifest `2026.11.1`) and other shipped media. **The app is not release-ready while any row below is marked _placeholder_ or _development_.** `ManifestTests.testBundledManifestHonestlyReportsPlaceholders` and the backend's production publish check both fail closed on placeholders.

## How to deliver final artwork

1. One PNG per pose, transparent background, character centred, at least 1024 × 1024 px, same lighting, proportions, colours and facial identity as the reference sheet (`Design/Reference/Supplied`).
2. Save the source as `Design/Reference/Supplied/<characterID>_<poseID>.png`.
3. In the manifest, set that artwork's `status` to `final` and increase `version`.
4. Run `python3 Tools/artwork/build_artwork.py` (regenerates the asset catalog image set) and `python3 Tools/localization/check_strings.py`.
5. Update the pose description strings `art.<character>.<pose>` in `Localizable.xcstrings` if the final pose differs from the brief.
6. Never mirror, recolour or redraw one illustration to make another pose, and never ship a pose sheet as a single card image. Both cards of a pair always use the same single file.

## Supplied illustrations (10 — signature poses, free tier)

These came from the supplied character sheet as individual files. `build_artwork.py` cleaned them (removed near-transparent background specks and edge halos, made the ~99 % opaque body fully opaque, trimmed and centred on a 1024 px canvas). **Art-director sign-off on the processed versions is still needed.**

| Asset ID | Character | Pose | Source | Status |
| --- | --- | --- | --- | --- |
| `momo.signature` | Momo (golden-and-cream puppy) | signature | `Design/Reference/Supplied/momo_signature.png` | final art supplied — sign-off pending |
| `iris.signature` | Iris (lilac kitten with white chest) | signature | `Design/Reference/Supplied/iris_signature.png` | final art supplied — sign-off pending |
| `nori.signature` | Nori (pale-blue elephant) | signature | `Design/Reference/Supplied/nori_signature.png` | final art supplied — sign-off pending |
| `sprout.signature` | Sprout (sage-green dinosaur) | signature | `Design/Reference/Supplied/sprout_signature.png` | final art supplied — sign-off pending |
| `mochi.signature` | Mochi (peach rabbit) | signature | `Design/Reference/Supplied/mochi_signature.png` | final art supplied — sign-off pending |
| `sunny.signature` | Sunny (yellow duck) | signature | `Design/Reference/Supplied/sunny_signature.png` | final art supplied — sign-off pending |
| `maple.signature` | Maple (beige bear) | signature | `Design/Reference/Supplied/maple_signature.png` | final art supplied — sign-off pending |
| `clover.signature` | Clover (sage-green turtle) | signature | `Design/Reference/Supplied/clover_signature.png` | final art supplied — sign-off pending |
| `rusty.signature` | Rusty (rust-red panda) | signature | `Design/Reference/Supplied/rusty_signature.png` | final art supplied — sign-off pending |
| `pebble.signature` | Pebble (blue penguin) | signature | `Design/Reference/Supplied/pebble_signature.png` | final art supplied — sign-off pending |

## Missing final illustrations (20 — premium tier)

Currently shipped as **development placeholders**: the character's signature art, tilted, on a tinted disc with a large pose badge (★ = play, ☾ = nap) and a “DEV PLACEHOLDER” banner, so Exact Pose boards stay testable and the poses stay visibly distinct. They are not release artwork.

| Asset ID | Character | Pose | Brief for the illustrator | Status |
| --- | --- | --- | --- | --- |
| `momo.play` | Momo (golden-and-cream puppy) | play | sitting in a play bow with tail up, tongue out | **placeholder — final art missing** |
| `momo.nap` | Momo (golden-and-cream puppy) | nap | curled up asleep, ears draped, paws tucked | **placeholder — final art missing** |
| `iris.play` | Iris (lilac kitten with white chest) | play | batting at a soft ball of yarn | **placeholder — final art missing** |
| `iris.nap` | Iris (lilac kitten with white chest) | nap | curled in a ball, tail wrapped around, eyes closed | **placeholder — final art missing** |
| `nori.play` | Nori (pale-blue elephant) | play | splashing a little arc of water bubbles from the trunk | **placeholder — final art missing** |
| `nori.nap` | Nori (pale-blue elephant) | nap | lying down, trunk curled, eyes closed | **placeholder — final art missing** |
| `sprout.play` | Sprout (sage-green dinosaur) | play | mid-hop with arms up, mouth open in a laugh | **placeholder — final art missing** |
| `sprout.nap` | Sprout (sage-green dinosaur) | nap | sitting, leaning on its tail, dozing | **placeholder — final art missing** |
| `mochi.play` | Mochi (peach rabbit) | play | hopping, ears back, feet off the ground | **placeholder — final art missing** |
| `mochi.nap` | Mochi (peach rabbit) | nap | loaf-shaped, ears folded down, eyes closed | **placeholder — final art missing** |
| `sunny.play` | Sunny (yellow duck) | play | paddling/splashing with one wing raised | **placeholder — final art missing** |
| `sunny.nap` | Sunny (yellow duck) | nap | sitting, head tucked into a wing | **placeholder — final art missing** |
| `maple.play` | Maple (beige bear) | play | hugging a soft ball, sitting | **placeholder — final art missing** |
| `maple.nap` | Maple (beige bear) | nap | lying on its back or side, paws on tummy, asleep | **placeholder — final art missing** |
| `clover.play` | Clover (sage-green turtle) | play | stretching up on tiptoes with a big smile | **placeholder — final art missing** |
| `clover.nap` | Clover (sage-green turtle) | nap | head and legs tucked in, sleepy eyes peeking | **placeholder — final art missing** |
| `rusty.play` | Rusty (rust-red panda) | play | hugging its striped tail, seated | **placeholder — final art missing** |
| `rusty.nap` | Rusty (rust-red panda) | nap | curled up with tail wrapped over its nose | **placeholder — final art missing** |
| `pebble.play` | Pebble (blue penguin) | play | sliding on its tummy, flippers back | **placeholder — final art missing** |
| `pebble.nap` | Pebble (blue penguin) | nap | standing with eyes closed, flippers folded | **placeholder — final art missing** |

## Other media

| Item | Location | Status |
| --- | --- | --- |
| App icon (1024 px) | `AppIcon.appiconset` ← `Design/Reference/Supplied/ui_app_icon.png` | final art supplied. Delivered with white pre-rounded corners; `build_ui_graphics.py` fills them from the surrounding art (iPadOS applies its own mask). Sign-off pending — ideally request a square, unrounded master from the designer |
| “Animal Pairs” wordmark | `UI/brand_wordmark` ← `ui_wordmark.png` | final art supplied — background haze removed |
| Group illustration (all ten) | `UI/home_group_animals` ← `ui_group_animals.png` | final art supplied — used on Welcome and Home only, never as a card image |
| Trophy badge | `UI/results_trophy` ← `ui_trophy_badge.png` | final art supplied — localized “Well done!” is drawn on the ribbon by the app |
| Card back | `UI/card_back` ← `ui_card_back.webp` | final art supplied — used on every card; the board uses its 0.735 width:height ratio so it is never stretched |
| Floral corner accents | `UI/decor_corner_*` ← `ui_floral_corners.png` | final art supplied — split into four corners; used on Welcome, Home and Results, never on the game board |
| ElevenLabs batch 1 (8 core sounds) | `AnimalPairs/Resources/Sounds/` | **approved** and bundled |
| ElevenLabs batch 2 (11 interface & reward sounds) | `Design/Audio/Review/` | **awaiting your review** — not bundled. `star_earn`, `badge_reveal`, `new_best` have no game feature to attach to; `try_again` overlaps `pair_miss` |
| ElevenLabs batch 3 (10 animal cues) | — | planned, after batch 2 review |
| Thai voice lines (4) | — | planned; **needs a decision** (the app is English-only) |
| Synthesized tones (`flip`, `match`, `mismatch`, `complete`, `tap`, `hint_synth`) | `AnimalPairs/Resources/Sounds` ← `Tools/audio/build_sounds.py` | fallbacks only |
| Full sound list, prompts, credits and status | `Tools/audio/audio_manifest.json` | source of truth |
| Launch screen | Info.plist `UILaunchScreen` (ivory colour) | final (colour only) |
| App Store screenshots, preview video, marketing text | — | **missing** |
| Privacy policy and support pages (URLs) | build settings `AP_PRIVACY_POLICY_URL`, `AP_SUPPORT_URL` | **missing** — the Parents screen explains this until set |
