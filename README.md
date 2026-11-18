# Animal Pairs

A gentle animal memory-matching game for iPad, for children of about 3–7.
Ten soft animal friends — Momo, Iris, Nori, Sprout, Mochi, Sunny, Maple,
Clover, Rusty and Pebble — hide under lavender cards. No timers, no lives, no
failure screens, no ads, no accounts, and it works fully offline.

* **Classic**: match two cards of the same animal (one pose per animal).
* **Exact Pose** (Animal Pairs Plus): the board mixes several poses of the same
  animal; a pair must be the same animal *and* the same pose.
* Boards: 6 (3×2), 12 (4×3), 16 (4×4) and 20 (5×4) cards. Classic with 6
  cards is free; the rest is part of the optional monthly subscription
  **Animal Pairs Plus** (see [below](#animal-pairs-plus-monthly-subscription)).
* Unlimited gentle hints, VoiceOver, Dynamic Type and
  Reduce Motion support.

> **Artwork status:** all 80 animal pictures are final supplied artwork — see
> [ASSET_CHECKLIST.md](ASSET_CHECKLIST.md).

## Requirements

* Xcode 16 or later (the project uses synchronized folder groups), iPadOS 17+
  SDK. Swift 5 language mode.
* For on-device runs and real purchases: an Apple Developer account.

## Build and run

1. Open `AnimalPairs.xcodeproj`.
2. Select the **AnimalPairs** target → *Signing & Capabilities* → choose your
   team. Change the bundle identifier (`com.example.AnimalPairs`) to one you own.
3. Choose the shared **AnimalPairs** scheme and an iPad simulator, then Run.
   The scheme's Run action uses `Config/Products.storekit`, so Animal Pairs
   Plus can be subscribed to locally (no money, no Apple Account, no App Store
   Connect setup).

Command line:

```bash
xcodebuild -project AnimalPairs.xcodeproj -scheme AnimalPairs \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3)' build test
xcodebuild -project AnimalPairs.xcodeproj -scheme AnimalPairs \
  -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

(Pick any installed iPhone and iPad simulator; `xcrun simctl list devices` lists them.)

## Tests

| Suite | Where | How |
| --- | --- | --- |
| `AnimalPairsCoreTests` (94 tests) — deck cardinality and mode rules, exact image vs same-animal/different-pose, rapid taps, stale callbacks, hint accounting, pause/normalize, snapshot corruption/migration/restore, history de-duplication and trimming, entitlement decisions, parental gate | `Packages/AnimalPairsKit` | `swift test` in that folder (macOS or Linux), or Xcode test action |
| `AnimalPairsTests` — SwiftData history, background → save → relaunch → resume without reshuffle, corrupt snapshot vs history, reset keeps purchases, parent-access expiry, VoiceOver labels never reveal covered cards, English-only text and bundle, **StoreKitTest** subscription states (subscribe, relaunch, Ask to Buy pending, cancel, failure, expiry, refund, restore) | `AnimalPairsTests/` (hosted by the app) | Xcode test action on an iPad simulator |
| Backend (18 tests) | `backend/` | see [backend/README.md](backend/README.md) |
| String Catalog coverage (every key used has English text) | `Tools/localization/check_strings.py` | `python3 Tools/localization/check_strings.py` |

## Testing on a physical iPad (needs your Apple account)

1. Connect the iPad, enable Developer Mode (Settings → Privacy & Security), select
   it as the run destination, and run with your signing team.
2. **Local StoreKit on device:** the scheme's StoreKit configuration also
   applies to device runs launched from Xcode.
3. **Sandbox purchases:** create the subscription in App Store Connect with the
   product ID you configure (see [APP_STORE.md](APP_STORE.md)), add a Sandbox tester (Users and Access →
   Sandbox), sign in on the iPad under Settings → App Store → Sandbox Account, then
   run with the scheme's StoreKit configuration set to *None*
   (Edit Scheme → Run → Options).
4. Things worth checking by hand: Ask to Buy (Family Sharing child account),
   refund and expiry via Sandbox, Restore Purchases on a second device, VoiceOver with the
   rotor, Larger Text, Reduce Motion, Stage Manager / Split View resizing during a
   round (the board must keep its order and progress), and backgrounding during
   the 1.2 s mismatch window.

## Configuration

All configurable values are build settings on the **AnimalPairs** target
(*Build Settings → User-Defined*) and flow into Info.plist:

| Setting | Default | Purpose |
| --- | --- | --- |
| `AP_PLUS_PRODUCT_ID` | `com.example.animalpairs.plus.monthly` | Monthly auto-renewable *Animal Pairs Plus* product ID. Must match App Store Connect and `Config/Products.storekit` — see [Product ID and configuration](#product-id-and-configuration). |
| `AP_TERMS_OF_USE_URL` | empty | `https://` Terms of Use (EULA), opened from Parents (behind the gate). Required for a subscription. |
| `AP_PRIVACY_POLICY_URL` | empty | `https://` privacy policy, opened from Parents (behind the gate). Required for a subscription. |
| `AP_SUPPORT_URL` | empty | `https://` support page. |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.example.AnimalPairs` | Replace with your own. |

When a value is missing the app says so in the Parents area instead of pretending
a link or product works.

## How it is built

```
AnimalPairs.xcodeproj         Xcode 16 project; shared scheme with StoreKit config
AnimalPairs/                  SwiftUI app (synchronized folder)
  App/                        App entry, AppModel (routing, lifecycle), configuration
  Screens/                    Home, Setup, Game board, Pause/Results, Parental gate, Parents
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
poses each (for 3 pairs: two poses of one animal plus one other). Each animal
has eight poses (signature, play, nap, wave, celebrate, football, golf, cooking); Exact Pose never
deals two poses of one animal that the manifest marks as look-alikes
(`lookalikePoseGroups`), so the difference is always clear. Both cards of a
pair are the same picture, and a card's picture never changes during a round.
A round saved with a pose that has since been retired (Stretch) resumes with
another pose of the same animal instead of being discarded.
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

**Purchases.** One optional monthly auto-renewable subscription, *Animal Pairs
Plus* — see [Animal Pairs Plus](#animal-pairs-plus-monthly-subscription). Debug
builds have a *Simulate Animal Pairs Plus* switch in Parents; it is compiled out
of Release builds.

**Parents area.** Reached through an adult gate (a multiplication question in
words with a large keypad, or a standard text field as the accessible
alternative). It is a speed bump, not age verification or consent. Access is
revoked on leaving, on backgrounding and after five minutes. Purchases, restore,
privacy and support links all live behind it.

**Privacy.** No names, birthdays, emails, photos, location, advertising IDs,
accounts, chat or third-party analytics. Progress stays on the device. A
privacy manifest (`PrivacyInfo.xcprivacy`) declares the only required-reason
API used (UserDefaults).

## Animal Pairs Plus (monthly subscription)

One optional auto-renewing monthly subscription, **Animal Pairs Plus**, in
one subscription group. There are no ads and nothing else to buy. Values to
enter in App Store Connect, App Review notes and the release checklist are in
[APP_STORE.md](APP_STORE.md).

### Free vs Plus

| Free for everyone | Added by **Animal Pairs Plus** |
| --- | --- |
| **Classic** mode, **6 cards** | **12-, 16- and 20-card** boards |
| The 10 default animal pictures | **Exact Pose** mode |
| Sounds, music, animal clips, hints, progress, Parents | **70 more pictures**: every friend playing, napping, waving, celebrating, playing football, playing golf and cooking |

Only features that exist today are listed; no future packs are shown or
promised. Subscribing, restoring or expiring never touches game progress or
history (`ContentAccessPolicy`, AnimalPairsCore).

### Children never reach a purchase

On the Setup screen a locked board size or Exact Pose shows a gentle note
("Part of Animal Pairs Plus — ask a grown-up") with an **Ask a grown-up**
button that opens the **adult gate**, never a purchase sheet. Everything that
spends money or leaves the app sits behind the gate in **Parents → Animal
Pairs Plus**:

* what Plus includes today, the **localized price and period from StoreKit**
  (e.g. "$1.99 per month"; never hard-coded), that it renews automatically
  and how to cancel;
* **Subscribe** (`Product.purchase` through SwiftUI's `PurchaseAction`), disabled
  while a request is running so it cannot be sent twice;
* **Restore Purchases** (`AppStore.sync()`) with "restored" / "nothing to
  restore" / error messages;
* **Manage Subscription** (`manageSubscriptionsSheet`) and, when not subscribed,
  **Redeem Offer Code** (Apple's sheet);
* **Terms of Use** and **Privacy Policy** links (`AP_TERMS_OF_USE_URL`,
  `AP_PRIVACY_POLICY_URL`); a missing URL is shown as "not set yet" instead of
  a broken link;
* when subscribed: "renews on …" / "ends on …" and a billing-problem note during
  Apple's grace period.

### How access is decided

* Only **verified** StoreKit 2 transactions for `AP_PLUS_PRODUCT_ID` of type
  auto-renewable count; unverified, upgraded-away, revoked/refunded and
  expired transactions never unlock (`EntitlementResolver`, AnimalPairsCore,
  unit-tested).
* `Product.SubscriptionInfo.status` is also read: **subscribed** and
  **grace period** keep Plus; **billing retry**, **expired** and **revoked** do not.
* Refreshed at launch, on returning to the foreground, after Subscribe, after
  Restore, after the Manage sheet closes, on every `Transaction.updates` event,
  and automatically just after the current period's end date.
* **Pending** (Ask to Buy), **cancelled**, **failed verification** and network
  errors each show their own message and change nothing.
* **Offline / network failure:** the last verified transaction ID and its
  **period end date** are cached. If StoreKit cannot answer, Plus is kept only
  until that date — never longer, and a completed scan without the entitlement
  (expired, refunded) locks again. A plain UserDefaults flag never unlocks.
* **Other devices:** the subscription belongs to the Apple Account, so it is
  active on every iPhone and iPad signed in to it; **Restore Purchases** forces
  a sync after a reinstall. Family Sharing is off.

### Product ID and configuration

Everything is set in one place — the **AnimalPairs** target's build settings
(documented in `AnimalPairs/App/AppConfiguration.swift`):

| Build setting | Now | Final value |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.example.AnimalPairs` (placeholder) | your bundle ID |
| `AP_PLUS_PRODUCT_ID` | `com.example.animalpairs.plus.monthly` (placeholder) | suggested **`<bundle ID>.plus.monthly`** |
| `AP_TERMS_OF_USE_URL` | empty | Terms of Use page (Apple's standard EULA or your own) |
| `AP_PRIVACY_POLICY_URL` | empty | Little Penguin Studio privacy policy |
| `AP_SUPPORT_URL` | empty | support page (also needed in App Store Connect) |

Also change `productID` in `Config/Products.storekit` to match
(`PurchaseTests` fails if they differ). Debug builds show a note in Parents
while the placeholder ID is used. A product ID can never be reused once
created in App Store Connect.

### Testing

| Where | What it proves | How |
| --- | --- | --- |
| **Local StoreKit** — `Config/Products.storekit` (one group, one monthly subscription, in the scheme) and `AnimalPairsTests/PurchaseTests.swift` (`SKTestSession`) | product is monthly auto-renewable with a StoreKit price; free = Classic 6 only; subscribe → relaunch stays Plus; Ask to Buy pending; cancel; failure; expiry locks; refund locks; restore of an existing subscription; restore with nothing; an expired cached period is not honoured; offline launch inside the paid period; a UserDefaults flag never unlocks | Xcode → Product → Test on an iPhone and an iPad simulator. By hand: Debug → StoreKit → Manage Transactions (expire, refund, Ask to Buy); Editor → Subscription Renewal Rate to speed renewals. |
| **Sandbox** — a sandbox Apple Account (never a real one) | real App Store sheet and price, renewals, cancel in Manage Subscription, restore on a second device | sign in under Settings → Developer → Sandbox Apple Account; set the scheme's StoreKit Configuration to *None*. |
| **TestFlight** | the same with the production product | after the subscription is submitted with a build. |

No real purchases, personal credentials or live customer accounts are needed
or used for any of these.

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
  (The opening video plays its soundtrack if either Music or Sound Effects is on.)
* **Speaker button** (Home and the game board) — one clear control for *all*
  game sound: if music or sound effects are on, a tap turns both off; when
  both are off, a tap turns both on. The choice is saved; parents can still set
  each one separately in Settings (the Settings footer explains this).
* **Voice** — narration; no approved English recordings exist yet, so it is silent.

### Opening video

`AnimalPairs/Resources/Video/opening_video.mp4` (720×1280 portrait, 8 s, H.264 +
AAC) plays **once per app launch**, then hands over to Home (there is no separate
introduction page, on first launch or ever). It
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

| Screen | Track (`AnimalPairs/Resources/Music/`) | Length |
| --- | --- | --- |
| Home, choosing a board **and playing** (one continuous loop — moving between them never restarts it) | `music_playground.caf` | 40.62 s loop |
| Results | `music_celebration.caf`, fading in 3 s after the jingle | 36.27 s loop |
| Parents area and gate | `music_meadow.caf` | 40.02 s loop |
| Opening video | none (the video has its own soundtrack) | — |

`music_focus.caf` (39.94 s) is bundled but not assigned to a screen.

**Files.** Apple Lossless (ALAC) 16-bit 48 kHz stereo `.caf`, encoded from the
loop masters. ALAC has no encoder delay, so each file decodes to exactly the
loop (`music_tracks.json` holds the frame counts; `--bundle` and the app tests
check them) and `AVAudioPlayer`'s `numberOfLoops = -1` repeats it without a gap.
About 10.5 MB for the four.

**`BackgroundMusicPlayer`** (`AnimalPairs/Audio/BackgroundMusicPlayer.swift`) —
one persistent controller owned by `AudioManager`, which `AppModel` owns:

* One `AVAudioPlayer` per track, created once and kept; one *current* track.
  The same track on the next screen changes nothing; a different track fades
  the old one out (1 s) while the new one fades in (1.5 s).
* Quiet (0.3 of full scale; loops mastered at −24 LUFS) and dipped to 35 %
  while an animal clip plays, then restored over 0.8 s.
* **Background**: paused at once, keeping the position and the intention to
  play. **Foreground**: the session is reactivated off the main thread and the
  same player resumes from that position — unless Music is off, another app is
  playing audio, or an interruption asked not to resume. No background-audio
  capability: music pauses while another app is in use.
* **Interruptions** (calls, alarms, Siri): paused; resumed when the end of the
  interruption carries `shouldResume`, otherwise at the next screen or
  foreground. iOS can report the app's own suspension as an interruption that
  never ends — that is ignored, and becoming active clears any stale state.
* **Route changes**: headphones or Bluetooth disconnecting pause the music in
  place until the next screen or foreground.
* **Failures**: a track that cannot load or play after one rebuilt player is
  disabled for this launch; activation failure is retried only at the next
  foreground or interruption end (sounds still try to play meanwhile); a media
  services reset rebuilds the players.
* Debug builds log transitions, activation failures and recoveries
  (`AudioDebugLog`, category "Audio"), each repeated message only once.

**Audio session** (`AudioSessionController`, shared by music and effects):
category `.ambient` + `.mixWithOthers` (Ring/Silent switch respected, other
apps never stopped), set once. `setActive(true)` runs on a private serial
queue — at launch, on foreground, after an interruption and after a media
reset only — so it never blocks the main thread (no "This method can lead to UI
unresponsiveness…" warning). Requests are coalesced; a result that arrives
after the app left is discarded and asked for again on return. Music and
effects only start once the session is active, so nothing activates it
implicitly on the main thread, and the app never deactivates it — a short
sound cannot silence the music. (The async `activate` API is not used: a
background queue gives the same non-blocking behaviour on iOS 17, the
deployment target.)

**History of the missing music**:

1. Originally the loops were never bundled and the app had no music player.
2. The first engine-based player dropped each track while it was decoding.
3. It then looped on audio-engine configuration changes, re-activating the
   session on the main thread (the repeated warning).
4. Music did not come back after switching apps: iOS reported the suspension
   as an interruption, the player marked itself interrupted, and only an
   interruption "ended" — which never comes for a suspension — cleared it.
   The engine underneath could also be stopped by the system while its nodes
   still reported "playing". Replaced by the `AVAudioPlayer` design above.

The masters (`Design/Audio/Music/masters/`) and raw downloads
(`Design/Audio/Music/raw/`) are kept. `python3 Tools/audio/generate_elevenlabs_music.py
--bundle` re-encodes the loops into the app (and checks they are
sample-identical to the masters); `--verify` measures the loop joins.

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
