# App Store release: Full Game Unlock (one-time purchase)

Values for App Store Connect, App Review notes, listing text and what is still
open before the first release. Nothing here has been created, submitted or
published by Claude: every App Store Connect step below is yours to do.

## Still needed from you

| Item | Status | Where it goes |
| --- | --- | --- |
| **Bundle ID** | `com.littlesnowyowl.animalpairs` (app 6838152398). Xcode Cloud's `ci_scripts` stop an archive whose main app has any other identifier | `PRODUCT_BUNDLE_IDENTIFIER`, AnimalPairs target |
| **Product ID** | set in the project: **`com.littlesnowyowl.animalpairs.fullgame`**. It does **not** exist in App Store Connect until you create it (below). To use a different ID, change `AP_FULL_UNLOCK_PRODUCT_ID` and `productID` in `Config/Products.storekit` together | build setting + StoreKit file |
| **Price** | US$3.99 (set in App Store Connect). The local StoreKit test file mirrors it (3.99, US storefront) for simulator testing only; the app always shows the price StoreKit returns | App Store Connect → the in-app purchase → Price Schedule |
| **Family Sharing** | ❗ your decision (off in the local test file). Once turned on in App Store Connect it cannot be turned off | the in-app purchase → Family Sharing |
| **Privacy Policy URL** | set: `https://littlesnowyowl.com/games/animal-pairs/privacy/` (live, published policy; checked 24 Nov 2026) | `AP_PRIVACY_POLICY_URL`; App Store Connect → App Privacy → Privacy Policy URL |
| **Support URL** | set: `https://littlesnowyowl.com/games/animal-pairs/support/` (live; checked 24 Nov 2026) | `AP_SUPPORT_URL`; version page → Support URL |
| **Terms of Use** | set to Apple's standard EULA, `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` (your choice, recorded on the website 19 Nov 2026); shown in Parents | `AP_TERMS_OF_USE_URL` |

## Legacy website links (builds made before 24 Nov 2026)

Builds made before this change, including the build submitted to App Review
in November 2026, open the old website host from Parents:
`https://littlepenguinstudio.krai-thanawat.workers.dev/games/animal-pairs/privacy/`
and `/support/`. That host stopped serving when the website's Cloudflare Worker
was renamed on 23 Nov 2026. The website repository's branch
`claude/restore-legacy-workers-dev-urls` holds a small Worker
(`legacy-redirect/`) that takes the old name back and 301-redirects each path
to the same page on `https://littlesnowyowl.com`. Until it is deployed
(`cd legacy-redirect && npx wrangler deploy`), those older builds' links
return 404. Current builds use the `littlesnowyowl.com` URLs above.

## App Store Connect: the in-app purchase

1. **Business → Agreements, Tax and Banking:** the **Paid Apps** agreement must be active.
2. **Apps → Animal Pairs → Monetization → In-App Purchases → +**

| Field | Value |
| --- | --- |
| Type | **Non-Consumable** |
| Reference name | **Full Game Unlock** |
| Product ID | **`com.littlesnowyowl.animalpairs.fullgame`** (must equal `AP_FULL_UNLOCK_PRODUCT_ID`; a product ID can never be reused) |
| Availability | the countries or regions where the app is sold (the app is English only) |
| Price | your choice (see above) |
| Family Sharing | your choice (see above) |
| Localization, English (U.S.): display name | **Full Game Unlock** |
| Localization, English (U.S.): description | **Classic 16 & 20 cards, Exact Pose, 70 more pictures.** (52 characters; the limit is 55) |
| Review screenshot | Parents → **Full Game Unlock** on iPhone, showing "One-time purchase", what it unlocks, the price and the Buy button. Take it from a simulator run with the local StoreKit file, or a sandbox build |
| Review notes | see below |

3. **Submit it with the app version.** A first in-app purchase must be reviewed
   together with a new app version: on the version page, under *In-App
   Purchases and Subscriptions*, select **Full Game Unlock** before *Add for
   Review*.
4. **The old subscription:** "Animal Pairs Plus" (`com.example.animalpairs.plus.monthly`)
   existed only in the local StoreKit test file and was never sold. If you
   created it in App Store Connect anyway, do not attach it to the version and
   remove it from sale (or delete it while it has never been submitted).

## App Review notes (paste into "Notes" for the version and the in-app purchase)

```
Animal Pairs is free to play with no time limit: Classic mode with 6 or 12
cards. One optional one-time, non-consumable in-app purchase, "Full Game
Unlock", adds Classic with 16 and 20 cards, Exact Pose mode at every board
size, and 70 more animal pictures. There are no subscriptions, ads or accounts.

Parental gate: every purchase, Restore Purchases, offer codes and external
link (Terms of Use, Privacy Policy, Support) is behind an adult gate. On the Home screen tap
the gear button (top corner, "Parents and settings"). The gate asks a
multiplication question written in words (for example "What is seven times
eight?"); enter the answer on the number pad and tap Check.

Purchase screen: after the gate, the Parents screen opens. The "Full Game
Unlock" section shows "One-time purchase", what it unlocks, the price from the
App Store, Buy, Restore Purchases, Redeem Offer Code, Terms of Use and the
Privacy Policy.

Locked features: from Home, tap Play. Classic with 16 or 20 cards and Exact
Pose show a lock. Tapping one shows a short message for the child with an
"Ask a grown-up" button that opens the same parental gate. A child can never
start a purchase from the game.

Restore: Parents → Full Game Unlock → Restore Purchases. A message confirms the
purchase was restored, or that none was found for this Apple Account.
```

## App Store listing draft (English)

**Subtitle** (30 characters max): `A gentle animal memory game` (27)

**Promotional text:**
Ten soft animal friends hide under the cards. Classic matching with 6 or 12
cards is free to play, as often as you like.

**Description:**
```
Turn over two cards, remember where everyone is, and find the matching pairs.
Ten friendly animals — Momo, Iris, Nori, Sprout, Mochi, Sunny, Maple, Clover,
Rusty and Pebble — make a happy sound when their pair is found.

• No timers, no lives, no failure screens
• Unlimited gentle hints
• Large cards and simple controls, made for young children
• Works offline; no accounts, no ads, no tracking
• VoiceOver, Larger Text and Reduce Motion support

FREE TO PLAY
Classic mode with 6 or 12 cards, with unlimited play.

FULL GAME UNLOCK — ONE-TIME PURCHASE
One optional in-app purchase, bought once by a grown-up in the Parents area
(behind a grown-ups check). It adds:
• Classic mode with 16 and 20 cards
• Exact Pose mode with 6, 12, 16 and 20 cards: match the same animal in the
  same pose
• 70 more animal pictures: every friend in seven more poses
It is not a subscription and never expires. Restore Purchases brings it back on
any iPhone or iPad signed in to the same Apple Account.
```

**In-App Purchases** list on the product page is generated by Apple from the
in-app purchase's display name and price.

## Release checklist

- [ ] Final bundle ID set; product ID created in App Store Connect exactly as above
- [ ] Price and Family Sharing chosen
- [ ] Build and test on an iPhone and an iPad simulator (`xcodebuild … build test`, see README), including `PurchaseTests`
- [ ] Sandbox check with a sandbox Apple Account: buy, Restore on a second device, refund (Debug → StoreKit or sandbox)
- [ ] Review screenshot of Parents → Full Game Unlock; in-app purchase attached to the version
- [ ] App Store screenshots, description and promotional text (draft above)
- [ ] Release signing and a TestFlight round before submitting
