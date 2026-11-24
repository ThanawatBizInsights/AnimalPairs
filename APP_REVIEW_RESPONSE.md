# Draft reply to App Review: data collection and third parties

**Status: draft, not sent.** Based on a source audit of branch
`claude/app-review-release` (the code for the new build), 24 Nov 2026. Items
marked **[confirm]** need the owner's confirmation before sending.

## Reply (paste into Resolution Center)

```
Hello,

Thank you for your questions. Animal Pairs: Match & Play is a matching game for
young children. Here are the answers for the build submitted with this reply.

1. Does the app include third-party analytics? What data is collected?
No. The app contains no third-party analytics, crash-reporting or attribution
code. Its only code dependency is our own local Swift package (game logic); it
otherwise uses Apple frameworks only (SwiftUI, Foundation, SwiftData,
AVFoundation, StoreKit, UIKit, Observation, Combine). The app does not collect
any data and does not send any data to us or to anyone else.

2. Does the app include third-party advertising?
No. There is no advertising of any kind and no advertising SDK. The app does
not access the advertising identifier and does not use App Tracking
Transparency, SKAdNetwork or AdServices.

3. Is data shared with third parties? For what purpose and where is it stored?
No data is shared with third parties, and none is stored by us. The only
external service the app uses is Apple's own StoreKit, for the optional
one-time in-app purchase "Full Game Unlock": when a grown-up opens the Parents
area (behind a parental gate) to see the price, buy, restore purchases or
redeem an offer code, the request goes to the App Store, and Apple handles the
payment and the Apple Account. The app checks Apple's signed transaction on
the device to decide whether the extra content is unlocked.

4. Does the app collect any other user or device data? Explain every use.
The app does not collect user or device data. It does not ask for any
permission (no camera, microphone, photos, location, contacts or
notifications), has no accounts, sign-in, chat or web views, and does not use
device identifiers. It makes no network connections of its own.

To work offline, it keeps the following on the device only, never sent
anywhere:
- Settings: music, sound effects and voice on or off, whether the speaker
  button has muted all sound, and the last game mode and board size.
- Completed-game history shown to grown-ups in the Parents area: for each
  finished game, its start and end time, mode, board size, number of turns,
  hints used and pairs found (only the newest 100 are kept, plus overall
  totals).
- The round in progress (card layout and progress), saved while playing. The
  game does not offer to continue it after the app is closed; it is replaced
  by the next round.
- The ID of the verified Apple transaction for Full Game Unlock, so the
  purchase still works if the app starts before the App Store answers.
"Reset progress" in the Parents area removes the history and the saved
round; deleting the app removes everything. The history is not synced
through iCloud.

The app also reads the device's time since start-up (system uptime) only to
space out sound effects within the app; this is declared in the app's privacy
manifest with reason 35F9.1 and never leaves the device.

External links (Privacy Policy, Support, and Apple's standard Terms of Use)
are only in the Parents area behind the parental gate and open in the web
browser. If a parent chooses to email our support address, we use the message
only to reply and delete it 12 months after the last reply.

Our App Privacy answer is "Data Not Collected", and the privacy policy is at
https://littlesnowyowl.com/games/animal-pairs/privacy/

Best regards,
Thanawat Kraiananyawich (Little Snowy Owl Studio)
```

## Facts behind each statement (from the code)

| Statement | Evidence |
| --- | --- |
| No third-party SDKs | `project.pbxproj`: only `XCLocalSwiftPackageReference "Packages/AnimalPairsKit"`; its `Package.swift` has no dependencies; no Package.resolved, Podfile, Cartfile or binary frameworks. Imported modules: AVFoundation, AnimalPairsCore, Combine, Foundation, Observation, StoreKit, SwiftData, SwiftUI, UIKit, os (debug-only logging, compiled out of Release) |
| No network calls of its own | No `URLSession`, `URLRequest`, `NWConnection`, web views or sockets in `AnimalPairs/` or the package. Only StoreKit (`Product.products`, purchase, `AppStore.sync`, `Transaction.currentEntitlements/updates/latest`, offer-code sheet) |
| No identifiers / tracking | No `identifierForVendor`, `ASIdentifierManager`, `ATTrackingManager`, `SKAdNetwork`, `AdServices`, `DeviceCheck`. Privacy manifest: `NSPrivacyTracking = false`, no tracking domains, no collected data types |
| No permissions | Info.plist has no `NS…UsageDescription`; no entitlements file (so no iCloud/CloudKit, push, etc.) |
| Local storage | UserDefaults keys `settings.soundEnabled`, `settings.voiceEnabled`, `settings.musicEnabled`, `settings.allSoundMuted`, `settings.lastMode`, `settings.lastBoard`, `purchases.fullGameUnlock.verified`; SwiftData `Application Support/History/History.store` (`cloudKitDatabase: .none`); JSON `Application Support/Rounds/UnfinishedRound.json` |
| Required-reason APIs | UserDefaults (CA92.1) and system boot time (`ProcessInfo.systemUptime` in `AudioManager.swift`, 35F9.1), both declared in `PrivacyInfo.xcprivacy` |
| Parental gate | Purchase, Restore, offer codes and all three external links exist only in `ParentsView`, reached via `AppModel.openParentGate()` |
| The repo's `backend/` folder | Optional server code that the app never calls (no URL or network code in the app). Not part of the app binary |

## [confirm] before sending

1. **Signature and seller name**: "Thanawat Kraiananyawich (Little Snowy Owl Studio)" is taken from the published privacy policy; use the exact name shown as the seller in App Store Connect.
2. **Support email handling**: the website says support emails go to `littlepenguinsupport@icloud.com` (Apple iCloud Mail) and are deleted 12 months after the last reply. Confirm that is your practice, or remove that sentence.
3. **Website analytics**: the reply does not mention the website. The site's README says it has no analytics, cookies or trackers; if you enabled Cloudflare Web Analytics or similar, say so if Apple asks about the website.
4. **App Analytics in App Store Connect**: Apple may show you aggregated usage/crash data from users who opted in to share with developers. That is Apple's own service, not in the app; mention it only if asked.
5. **The backend** has never been deployed for the app (the app cannot reach it). Confirm.
6. **App Privacy answers** in App Store Connect are still "Data Not Collected" with no tracking.
