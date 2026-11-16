# Animal Pairs

A gentle animal memory-matching game for iPad, for children of about 3–7.
Ten soft animal friends — Momo, Iris, Nori, Sprout, Mochi, Sunny, Maple,
Clover, Rusty and Pebble — hide under lavender cards. No timers, no lives, no
failure screens, no ads, no accounts, and it works fully offline.

* **Classic**: match two cards of the same animal (one pose per animal).
* **Exact Pose** (full game): the board mixes several poses of the same
  animal; a pair must be the same animal *and* the same pose.
* Boards: 6 (3×2), 12 (4×3), 16 (4×4) and 20 (5×4) cards.
* Unlimited gentle hints, VoiceOver, Dynamic Type and
  Reduce Motion support.

> **Artwork status:** the ten supplied signature illustrations are bundled.
> The other 20 poses are clearly labelled **development placeholders** — see
> [ASSET_CHECKLIST.md](ASSET_CHECKLIST.md). The app is not release-ready
> until they are replaced.

## Requirements

* Xcode 16 or later (the project uses synchronized folder groups), iPadOS 17+
  SDK. Swift 5 language mode.
* For on-device runs and real purchases: an Apple Developer account.

## Build and run

1. Open `AnimalPairs.xcodeproj`.
2. Select the **AnimalPairs** target → *Signing & Capabilities* → choose your
   team. Change the bundle identifier (`com.example.AnimalPairs`) to one you own.
3. Choose the shared **AnimalPairs** scheme and an iPad simulator, then Run.
   The scheme's Run action uses `Config/Products.storekit`, so the full-game
   unlock can be bought locally with no App Store Connect setup.

Command line:

```bash
xcodebuild -project AnimalPairs.xcodeproj -scheme AnimalPairs \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3)' build test
```

(Pick any installed iPad simulator; `xcrun simctl list devices` lists them.)

## Tests

| Suite | Where | How |
| --- | --- | --- |
| `AnimalPairsCoreTests` (84 tests) — deck cardinality and mode rules, exact image vs same-animal/different-pose, rapid taps, stale callbacks, hint accounting, pause/normalize, snapshot corruption/migration/restore, history de-duplication and trimming, entitlement decisions, parental gate | `Packages/AnimalPairsKit` | `swift test` in that folder (macOS or Linux), or Xcode test action |
| `AnimalPairsTests` — SwiftData history, background → save → relaunch → resume without reshuffle, corrupt snapshot vs history, reset keeps purchases, parent-access expiry, VoiceOver labels never reveal covered cards, English-only text and bundle, **StoreKitTest** purchase states (success, Ask to Buy pending, failure, refund/revocation, restore) | `AnimalPairsTests/` (hosted by the app) | Xcode test action on an iPad simulator |
| Backend (17 tests) | `backend/` | see [backend/README.md](backend/README.md) |
| String Catalog coverage (every key used has English text) | `Tools/localization/check_strings.py` | `python3 Tools/localization/check_strings.py` |

## Testing on a physical iPad (needs your Apple account)

1. Connect the iPad, enable Developer Mode (Settings → Privacy & Security), select
   it as the run destination, and run with your signing team.
2. **Local StoreKit on device:** the scheme's StoreKit configuration also
   applies to device runs launched from Xcode.
3. **Sandbox purchases:** create the non-consumable in App Store Connect with the
   product ID you configure below, add a Sandbox tester (Users and Access →
   Sandbox), sign in on the iPad under Settings → App Store → Sandbox Account, then
   run with the scheme's StoreKit configuration set to *None*
   (Edit Scheme → Run → Options).
4. Things worth checking by hand: Ask to Buy (Family Sharing child account),
   refund via Sandbox, Restore purchases on a second device, VoiceOver with the
   rotor, Larger Text, Reduce Motion, Stage Manager / Split View resizing during a
   round (the board must keep its order and progress), and backgrounding during
   the 1.2 s mismatch window.

## Configuration

All configurable values are build settings on the **AnimalPairs** target
(*Build Settings → User-Defined*) and flow into Info.plist:

| Setting | Default | Purpose |
| --- | --- | --- |
| `AP_FULL_UNLOCK_PRODUCT_ID` | `com.example.animalpairs.fullgame` | Non-consumable *Full Game Unlock* product ID. Must match App Store Connect and `Config/Products.storekit` — see [Product ID](#product-id). |
| `AP_PRIVACY_POLICY_URL` | empty | `https://` privacy policy, opened from Parents (behind the gate). |
| `AP_SUPPORT_URL` | empty | `https://` support page. |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.example.AnimalPairs` | Replace with your own. |

When a value is missing the app says so in the Parents area instead of pretending
a link or product works.

## How it is built

```
AnimalPairs.xcodeproj         Xcode 16 project; shared scheme with StoreKit config
AnimalPairs/                  SwiftUI app (synchronized folder)
  App/                        App entry, AppModel (routing, lifecycle), configuration
  Screens/                    Welcome, Home, Setup, Game board, Pause/Results, Parental gate, Parents
  Game/                       GameSession (wraps the engine), sounds
  Persistence/                SwiftData history (versioned schema), settings
  Purchases/                  StoreKit 2 PurchaseManager
  Content/                    Bundled manifest loader, artwork image view
  Localization/               English text lookup over the String Catalog
  Design/                     Palette, button styles, background, brand graphic views
  Resources/                  ArtworkManifest.json, Localizable.xcstrings, sounds, privacy manifest
  Assets.xcassets/            30 artwork image sets, UI graphics, app icon, colours
AnimalPairsTests/             App-hosted XCTest suite
Packages/AnimalPairsKit/      Pure Swift engine (Foundation only) + tests
Config/                       Info.plist, Products.storekit
Design/Reference/Supplied/    The supplied illustrations and UI graphics, untouched
Tools/                        Artwork, sound and localization scripts
backend/                      Optional FastAPI service (not used by the app)
```

**Engine (`AnimalPairsCore`).** `DeckBuilder` picks artworks with an injectable
random generator: every pair key (the exact `AssetID`) appears exactly twice;
Classic uses distinct animals; Exact Pose uses at least two animals in two
poses each (for 3 pairs: two poses of one animal plus one other).
`RoundState` is the serial state machine `ready → oneRevealed → resolving →
ready/completed` with an orthogonal pause flag; it rejects taps on matched
cards, on the open card, and during resolution, counts one attempt per second
card, and records hints separately. `RoundController` adds timing: matches
commit after 0.6 s, mismatches cover together after 1.2 s, hint outlines fade
after 1.8 s. Every delayed callback is checked against the round ID, a
generation counter and the resolution token, and is cancelled on pause,
restart or exit, so stale work cannot touch a new round.

**Saving.** After every settled move, on pause and on backgrounding the
round is normalized (a pending match is committed once, a pending mismatch is
covered, a single open card is kept) and written as a versioned JSON snapshot
with an atomic write. On launch the snapshot is validated against the current
manifest, installed artwork and access level; anything invalid is moved aside
(never silently deleted). Home has no Resume button (it was removed from the
Home design), so a saved round is not offered after a relaunch. Completed
rounds go to SwiftData, unique by round ID; the newest 100 are kept and the
totals cover every round. If the store cannot be opened the file is left
untouched and an in-memory store is used for that session. Resetting progress
never touches purchases.

**Purchases.** One non-consumable, *Full Game Unlock*, which can be bought,
redeemed with an Apple gift code (offer code) or restored — see
[Full Game Unlock and gift codes](#full-game-unlock-and-gift-codes). Debug
builds have a *Simulate full unlock* switch in Parents; it is compiled out of
Release builds.

**Parents area.** Reached through an adult gate (a multiplication question in
words with a large keypad, or a standard text field as the accessible
alternative). It is a speed bump, not age verification or consent. Access is
revoked on leaving, on backgrounding and after five minutes. Purchases, restore,
privacy and support links all live behind it.

**Privacy.** No names, birthdays, emails, photos, location, advertising IDs,
accounts, chat or third-party analytics. Progress stays on the device. A
privacy manifest (`PrivacyInfo.xcprivacy`) declares the only required-reason
API used (UserDefaults).

## Full Game Unlock and gift codes

### What it unlocks

| Free for everyone | Added by **Full Game Unlock** |
| --- | --- |
| Classic mode | **Exact Pose** mode |
| 6- and 12-card boards | **16- and 20-card** boards |
| The 10 default animal pictures | **20 more pictures**: every friend playing and napping (currently development placeholders, see ASSET_CHECKLIST) |
| Sounds, animal clips, hints, progress, Parents | — |

Nothing that was free before is locked. Unlocking, restoring or redeeming never
touches game progress or history (`ContentAccessPolicy`, AnimalPairsCore).

### Parents section (behind the adult gate)

* **Full Game Unlocked** status (only from a *verified* StoreKit transaction;
  the debug "simulate" switch is labelled as such).
* **Unlock Full Game – {price}** (`Product.purchase` via SwiftUI's `PurchaseAction`).
* **Redeem Gift Code** — Apple's own sheet, `offerCodeRedemption(isPresented:onCompletion:)`
  (StoreKit, iOS 16.3+ for one-time purchases; the app targets iOS 17).
  Apple validates the code (wrong, expired, already used, not eligible) and
  explains problems inside its sheet. No codes are stored or checked by the app.
* **Restore Purchases** (`AppStore.sync()`).
* English messages for success, cancellation, unavailable product, network
  problems, "no code redeemed" and pending approval. Success is shown only
  after StoreKit has delivered a verified transaction for the unlock product.

### How ownership is decided

* Source of truth: StoreKit 2 **verified** transactions whose product ID is
  `AP_FULL_UNLOCK_PRODUCT_ID` and type non-consumable. Unverified transactions,
  other products and revoked/refunded transactions never unlock.
* Read at launch, whenever the app returns to the foreground (codes redeemed
  in the App Store app or via a redeem link), after a purchase, after the redeem
  sheet closes (waiting up to 8 s for the transaction) and on Restore;
  `Transaction.updates` is observed for the app's lifetime.
* Closing the redeem sheet never unlocks anything by itself.
* Offline: StoreKit keeps verified transactions on the device; in addition the
  ID of the last *verified* transaction is cached so a launch before StoreKit
  answers stays unlocked. It is not a "purchased" flag: a completed StoreKit
  scan without the entitlement (e.g. after a refund) locks again.

### Product ID

The project already uses **`com.example.animalpairs.fullgame`** (build setting
`AP_FULL_UNLOCK_PRODUCT_ID`, `Config/Products.storekit`). Because the bundle ID
`com.example.AnimalPairs` is a placeholder too, before creating anything in App
Store Connect set your real bundle ID and use the matching product ID, e.g.
bundle `com.yourstudio.AnimalPairs` → product **`com.yourstudio.animalpairs.fullgame`**.
Change it in three places: `PRODUCT_BUNDLE_IDENTIFIER`, `AP_FULL_UNLOCK_PRODUCT_ID`
(both targets' build settings) and `productID` in `Config/Products.storekit`
(`PurchaseTests` checks they match). A product ID can never be reused once created.

### App Store Connect setup

1. **Business → Agreements**: the Paid Apps agreement, tax and banking must be active
   (required for any in-app purchase, including free offer codes).
2. **Apps → Animal Pairs → Monetization → In-App Purchases → +**: type
   **Non-Consumable**, reference name **Full Game Unlock**, the product ID above.
3. Availability (all territories you sell in), a price, Family Sharing (on in
   the local config), an English localization (display name "Full Game",
   description "Adds Exact Pose, the 16- and 20-card boards and 20 extra animal
   pictures."), a review screenshot of the Parents section and review notes
   (the adult gate asks a multiplication question written in words before Parents opens).
4. Submit the in-app purchase **with an app version** (a first in-app purchase is
   reviewed together with a new version).

### Creating and giving out free codes

1. After the in-app purchase is approved: **In-App Purchases → Full Game Unlock →
   Offer Codes → Create**. Name it (e.g. "Gift – Full Game"), choose the
   territories and eligibility (people who don't own it yet) and **Free** as the
   price.
2. Choose the code type:
   * **One-time use codes** — App Store Connect generates a batch; download the
     list. Each code works once. Best for handing to individual parents.
   * **Custom codes** — a code you name (e.g. `PAIRSFRIENDS`) with a redemption
     limit. Easier to share, but anyone with the code can use it until the limit.
   * **Sandbox codes** — for testing with a sandbox Apple Account only.
   Set start/end dates; App Store Connect shows the current quantity and validity limits.
3. Give parents the code, or a link that pre-fills it:
   `https://apps.apple.com/redeem?ctx=offercodes&id=<Apple ID of the app>&code=<CODE>`.
   They can redeem it in **Parents → Redeem Gift Code**, by opening the link,
   or in the App Store app (account → Redeem Gift Card or Code). All three
   unlock the game on every device signed in to that Apple Account, and
   **Restore Purchases** brings it back after a reinstall.
4. App Store Connect reports redemptions per offer; codes can be deactivated there.

### Testing

| Where | What it proves | How |
| --- | --- | --- |
| **Simulated** — Xcode StoreKit configuration (`Config/Products.storekit`, already in the scheme), `AnimalPairsTests/PurchaseTests.swift` | purchase, Ask to Buy, failure, refund/revocation, restore after "reinstall" (empty cache), offline launch with a previously verified unlock, a plain UserDefaults flag never unlocks, redeem sheet closed without a code, network failure from the sheet, a transaction arriving while the sheet is open, a redemption made outside the app picked up on returning to the foreground | Xcode → Product → Test on an iPhone and an iPad simulator. Manual: run the app, Parents → Redeem Gift Code opens the sheet; Debug → StoreKit → Manage Transactions to add/delete/refund. |
| **Sandbox** — a sandbox Apple Account on a real iPhone and iPad, with **sandbox offer codes** from App Store Connect | real code validation by Apple: a valid free code unlocks; a wrong code, an expired offer and an already-used one-time code are refused in Apple's sheet and nothing unlocks; Cancel unlocks nothing; Restore after deleting and reinstalling; redeeming via the redeem link while the game is in the background, then returning | Settings → Developer (or App Store → Sandbox Account) to sign in; run a development build from Xcode **without** the StoreKit configuration (Edit Scheme → Options → StoreKit Configuration: None). |
| **TestFlight / release** | the same with production one-time-use and custom codes | after the in-app purchase is approved. |

Apple's sheet decides whether a code is valid, so invalid, expired and
already-redeemed codes can only be tested in the sandbox or later; the
simulated tests check that the game never unlocks without a verified
transaction in each of those cases.

## Sound effects and voice

All audio is local: the app plays bundled files from `AnimalPairs/Resources/Sounds/`
and **never contacts ElevenLabs** (or any server). `AudioManager`
(`AnimalPairs/Audio/AudioManager.swift`) preloads one player per sound, uses the
ambient audio session with `.mixWithOthers` (respects the Ring/Silent switch and
never stops other apps' audio) and
applies two unit-tested policies from the engine package:

* `SoundPlaybackPolicy` — the same sound restarts instead of layering, rapid
  repeats are dropped, at most three different sounds overlap.
* `NarrationPolicy` — spoken lines (when recordings exist) stay occasional:
  never two within 20 s, praise on every third match, encouragement after three
  misses in a row, "find a pair" only after two quiet minutes. Effects dip while
  a line plays. The same policy paces the `try_again` cue.

**Music**, **Sound Effects** and **Voice** are separate switches in Parents →
Settings, each remembered between launches:

* **Music** — the background loops only. **On** for a fresh install; a choice a
  family already made is kept (the setting is only stored once someone sets it).
* **Sound Effects** — card flips, match, mismatch, buttons and the animal clips.
  The speaker button on the home screen and on the game board is a shortcut for
  this switch only; the Settings footer says so. (The opening video plays its
  soundtrack if either Music or Sound Effects is on.)
* **Voice** — narration; no approved English recordings exist yet, so it is silent.

### Opening video

`AnimalPairs/Resources/Video/opening_video.mp4` (720×1280 portrait, 8 s, H.264 +
AAC) plays **once per app launch**, before Welcome (first launch) or Home. It
never replays when returning from a board. It is aspect-fit on a matching
backdrop so no animal is cropped, has a native **Skip** button, and moves on by
itself when it ends, fails to load, runs longer than 15 s, or the app goes to
the background. Its audio plays only if Sound Effects or Music is on, and all
other audio is stopped while it plays. The title and Play button stay native UI
on Home.

### Event map

| Moment | Sound |
| --- | --- |
| Card turns face up (first **and** second card) | `card_flip` only — never an animal clip |
| Mismatched pair turns back | `card_close` |
| Pair matched (not the last) | one random clip of **the matched animal** (any of its four), stopped with a 0.25 s fade at a natural pause about 1–2 s in; `pair_match` plays softer (60 %) under it. Without clips for that animal: `pair_match` at full level |
| Last pair matched | the matched animal's clip as above, with `board_complete` (or `perfect_round` when there were no misses) softer under it; the clip fades out when the Results screen opens |
| Second card is not a match (after 0.35 s) | `pair_miss` (always); no animal clip |
| Tap an animal on Home | a little hop, **no sound** (animal clips belong to confirmed matches only); the wobble animation never makes a sound |
| Results screen | `completion_jingle`, soft `confetti` at 0.4 s |
| **Play again** after a completed round | `try_again`, then the new round's `game_start` at 0.8 s |
| Round starts, restarts or resumes | `game_start` |
| Mode or board choice | `mode_select` |
| Back / Home / leaving Parents | `back` |
| Pause / resume | `pause` / `resume` |
| Hint | `hint` |
| Other buttons | `button_tap` |
| — | `star_earn`, `badge_reveal`, `new_best`: bundled but **unused** — the game has no stars, badges or best scores |

### Animal clips

Four clips per animal — `<animal>_greeting`, `_curious`, `_excited`, `_calm`
(e.g. `iris_curious.m4a`) — live in `AnimalPairs/Resources/Sounds/Animals/`
with `animal_clips.json` (each clip's length and `matchEnd`, the natural pause
where the shorter matched-pair version stops). `AnimalClipLibrary` and
`AnimalClipPicker` (AnimalPairsCore) only ever offer the requested animal's
own clips and never repeat the same clip twice in a row for an animal. Only
one clip plays at a time (a new one stops the previous one), clips stop when
a round is paused, restarted or left, and the Sound switch silences them at
once. An animal without clips simply plays none.

The clips were generated offline with ElevenLabs (`eleven_text_to_sound_v3`)
by `python3 Tools/audio/generate_animal_clips.py`: every paid take is kept in
`Design/Audio/Animals/takes/`, the chosen original download in
`Design/Audio/Animals/raw/`, and the processed 24-bit WAV master in
`Design/Audio/Animals/masters/`. Processing trims silence, shortens pauses
longer than 0.7 s to 0.45 s, caps clips at 5 s, sets −21 LUFS with peaks at or
below −3 dBFS (gentle limiter) and exports AAC mono 96 kbps `.m4a`.
`--verify` decodes every bundled clip; `Tools/audio/audio_sim/run.sh` (Linux)
plays thousands of simulated flips and matches, plus the music scenarios, through the real
`GameSession` and `AudioManager`.

Pending sounds are cancelled when a round is paused, restarted or left, and when
leaving the Results screen, so nothing spills into the next screen.
`python3 Tools/audio/check_audio.py` verifies that only approved files are
bundled, every file is in the app target, and no Thai remains.

### Background music

Why there was none before: the four loops had been generated but were left in
review (`Design/Audio/Review/`), never bundled; the app had no music player
(`hasMusic` was hard-coded false) and the Music switch defaulted to off and was
disabled. Now:

| Screen | Track (`AnimalPairs/Resources/Music/`) | Length |
| --- | --- | --- |
| Home, Welcome, choosing a board | `music_playground.m4a` | 40.62 s loop |
| Matching cards (and the pause menu) | `music_focus.m4a` | 39.94 s loop |
| Results | `music_celebration.m4a`, fading in 3 s after the jingle | 36.27 s loop |
| Parents area and gate | `music_meadow.m4a` | 40.02 s loop |
| Opening video | none (the video has its own soundtrack) | — |

`MusicPlayer` (`AnimalPairs/Audio/MusicPlayer.swift`, owned by `AudioManager`):

* **Gapless loops**: each track is decoded once into memory (off the main
  thread — gameplay never waits) and looped sample-exactly by an
  `AVAudioPlayerNode`; `music_tracks.json` holds each loop's exact frame count
  and any AAC encoder delay a decoder keeps is trimmed (`LoopTrim`).
* **One track at a time**: two decks only; a new screen fades the old track out
  (1 s) while the new one fades in (1.5 s); returning to the same screen or
  restarting a round keeps the music going without a new player.
* **Quiet**: 0.3 of full scale (the loops are mastered at −24 LUFS), well under
  the effects; it dips to 35 % within 0.15 s whenever an animal clip plays and
  comes back over 0.8 s (`MusicDuck`).
* **Lifecycle**: paused in the background and resumed (same position) when the
  app is active again; stopped for interruptions (calls, alarms) and resumed
  when they end; held after headphones are unplugged until the next screen or
  the app becomes active; silent while another app is playing audio
  (`secondaryAudioShouldBeSilencedHint`) and never stops that audio; restarted
  cleanly after an audio engine configuration change.

The masters (`Design/Audio/Music/masters/`) and raw downloads
(`Design/Audio/Music/raw/`) are kept. `python3 Tools/audio/generate_elevenlabs_music.py
--bundle` re-copies the reviewed loops into the app and rewrites
`music_tracks.json`; `--verify` decodes them and measures the loop joins.

### Generating, reviewing and approving (developer machine only)

`Tools/audio/audio_manifest.json` lists every sound with its prompt, requested
and final duration, credits and status (`planned` → `awaiting_review` →
`approved` / `rejected`). Requires `ffmpeg` (`brew install ffmpeg`) and
`pip install -r Tools/requirements.txt`.

```bash
export ELEVENLABS_API_KEY='sk_…'                    # this shell only; never commit it
python3 Tools/audio/generate_elevenlabs_sfx.py --status
python3 Tools/audio/generate_elevenlabs_sfx.py --batch batch2_interface --dry-run
#   → new effects land in Design/Audio/Review/ for listening
python3 Tools/audio/generate_elevenlabs_sfx.py --approve mode_select back
python3 Tools/audio/generate_elevenlabs_sfx.py --reject confetti --reason "too loud"
# Animal clips (bundled directly after the automatic checks):
python3 Tools/audio/generate_animal_clips.py --dry-run
python3 Tools/audio/generate_animal_clips.py                       # whatever is missing
python3 Tools/audio/generate_animal_clips.py --only mochi_excited --retake
python3 Tools/audio/generate_animal_clips.py --verify
python3 Tools/audio/check_audio.py
```

The generator uses `eleven_text_to_sound_v3`, never regenerates or overwrites an
approved sound, never prints or stores the key, budgets each call at 40
credits/second (the account has billed 10/s), stops before a batch's limit or
when the account runs low, records every call in
`Tools/audio/elevenlabs_credit_log.json`, rejects near-silent takes
automatically, and writes loudness-matched 44.1 kHz mono WAVs (loudest 50 ms at
−18 dBFS, peaks ≤ −3 dBFS).

## Tools

```bash
python3 -m pip install -r Tools/requirements.txt
python3 Tools/artwork/build_artwork.py     # clean supplied art, regenerate image sets and placeholders
python3 Tools/artwork/build_ui_graphics.py # app icon, wordmark, group art, trophy, floral corners, card back
python3 Tools/audio/build_sounds.py        # synthesized fallback tones
python3 Tools/audio/generate_elevenlabs_sfx.py --status    # ElevenLabs sounds (see Sound effects and voice)
python3 Tools/audio/check_audio.py         # bundled audio matches approvals
python3 Tools/localization/check_strings.py
```

## Verification status

In short: the
engine tests, String Catalog check and backend tests (SQLite and PostgreSQL,
including Alembic up/down) were run; the iOS app and its tests were authored
without access to Xcode and **have not yet been compiled or run** — please build
and run the test action once in Xcode.
