# Animal Pairs

A gentle animal memory-matching game for iPad, for children of about 3–7.
Ten soft animal friends — Momo, Luna, Nori, Sprout, Mochi, Sunny, Maple,
Clover, Rusty and Pebble — hide under lavender cards. No timers, no lives, no
failure screens, no ads, no accounts, and it works fully offline.

* **Classic**: match two cards of the same animal (one pose per animal).
* **Exact Pose** (full game): the board mixes several poses of the same
  animal; a pair must be the same animal *and* the same pose.
* Boards: 6 (3×2), 12 (4×3), 16 (4×4) and 20 (5×4) cards.
* Unlimited gentle hints, English and Thai, VoiceOver, Dynamic Type and
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
| `AnimalPairsCoreTests` (64 tests) — deck cardinality and mode rules, exact image vs same-animal/different-pose, rapid taps, stale callbacks, hint accounting, pause/normalize, snapshot corruption/migration/restore, history de-duplication and trimming, entitlement decisions, parental gate | `Packages/AnimalPairsKit` | `swift test` in that folder (macOS or Linux), or Xcode test action |
| `AnimalPairsTests` — SwiftData history, background → save → relaunch → resume without reshuffle, corrupt snapshot vs history, reset keeps purchases, parent-access expiry, VoiceOver labels never reveal covered cards, Thai/English lookups, **StoreKitTest** purchase states (success, Ask to Buy pending, failure, refund/revocation, restore) | `AnimalPairsTests/` (hosted by the app) | Xcode test action on an iPad simulator |
| Backend (17 tests) | `backend/` | see [backend/README.md](backend/README.md) |
| String Catalog coverage (en + th, format specifiers) | `Tools/localization/check_strings.py` | `python3 Tools/localization/check_strings.py` |

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
| `AP_FULL_UNLOCK_PRODUCT_ID` | `com.example.animalpairs.fullgame` | Non-consumable product ID. Must match App Store Connect and `Config/Products.storekit`. |
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
  Screens/                    Home, Setup, Game board, Pause/Results, Parental gate, Parents
  Game/                       GameSession (wraps the engine), sounds
  Persistence/                SwiftData history (versioned schema), settings
  Purchases/                  StoreKit 2 PurchaseManager
  Content/                    Bundled manifest loader, artwork image view
  Localization/               In-app language switching over the String Catalog
  Design/                     Palette, button styles, background (all SwiftUI)
  Resources/                  ArtworkManifest.json, Localizable.xcstrings, sounds, privacy manifest
  Assets.xcassets/            30 artwork image sets, app icon, colours
AnimalPairsTests/             App-hosted XCTest suite
Packages/AnimalPairsKit/      Pure Swift engine (Foundation only) + tests
Config/                       Info.plist, Products.storekit
Design/Reference/Supplied/    The supplied illustrations, untouched
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
(never silently deleted) and the game simply offers no Resume. Completed
rounds go to SwiftData, unique by round ID; the newest 100 are kept and the
totals cover every round. If the store cannot be opened the file is left
untouched and an in-memory store is used for that session. Resetting progress
never touches purchases.

**Purchases.** One non-consumable. Prices come from `Product.displayPrice`.
Access is delivered before a verified transaction is finished; unverified
transactions never unlock; `Transaction.updates` is observed for the app's
lifetime; refunds and revocations lock again. A previously verified unlock is
cached so it is honoured before StoreKit answers, but a completed StoreKit scan
with no entitlement is authoritative. Debug builds have a *Simulate full
unlock* switch in Parents; it is compiled out of Release builds.

**Parents area.** Reached through an adult gate (a multiplication question in
words with a large keypad, or a standard text field as the accessible
alternative). It is a speed bump, not age verification or consent. Access is
revoked on leaving, on backgrounding and after five minutes. Purchases, restore,
privacy and support links all live behind it.

**Privacy.** No names, birthdays, emails, photos, location, advertising IDs,
accounts, chat or third-party analytics. Progress stays on the device. A
privacy manifest (`PrivacyInfo.xcprivacy`) declares the only required-reason
API used (UserDefaults).

## Tools

```bash
python3 -m pip install -r Tools/requirements.txt
python3 Tools/artwork/build_artwork.py     # clean supplied art, regenerate image sets and placeholders
python3 Tools/artwork/build_app_icon.py    # development app icon
python3 Tools/audio/build_sounds.py        # regenerate the soft sound effects
python3 Tools/localization/check_strings.py
```

## Verification status

In short: the
engine tests, String Catalog check and backend tests (SQLite and PostgreSQL,
including Alembic up/down) were run; the iOS app and its tests were authored
without access to Xcode and **have not yet been compiled or run** — please build
and run the test action once in Xcode.
