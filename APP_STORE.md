# App Store release: Animal Pairs Plus

Values for App Store Connect, App Review notes and what is still open before
the first release. Nothing here has been submitted or published.

## Still needed from you

| Item | Status | Where it goes |
| --- | --- | --- |
| **Final bundle ID** | ❗ to supply. The project uses the placeholder `com.example.AnimalPairs` | `PRODUCT_BUNDLE_IDENTIFIER` (AnimalPairs and AnimalPairsTests targets) |
| **Product ID** | ❗ to confirm. Suggested: **`<bundle ID>.plus.monthly`**. The project uses the placeholder `com.example.animalpairs.plus.monthly` | `AP_PLUS_PRODUCT_ID` build setting and `productID` in `Config/Products.storekit` |
| **Terms of Use URL** | ❗ to supply; not verified | `AP_TERMS_OF_USE_URL`; App Store Connect → App Information → License Agreement (or your App Description) |
| **Privacy Policy URL** | ❗ to supply; not verified | `AP_PRIVACY_POLICY_URL`; App Store Connect → App Privacy → Privacy Policy URL |
| **Support URL** | ❗ to supply; not verified | `AP_SUPPORT_URL`; App Store Connect → version → Support URL |

No Little Penguin Studio web page for Animal Pairs could be found or opened
from the build machine, so no URL has been filled in. Every link is empty, and
the Parents screen says "not set yet" instead of opening a wrong page. If you
use Apple's standard licence instead of your own terms, it is usually
published at `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`.
Please open that URL yourself to confirm it before using it.

After setting the bundle ID and product ID, run the test action: `PurchaseTests`
fails if the build setting and the StoreKit file disagree.

## App Store Connect: subscription

**Business → Agreements, Tax and Banking:** the **Paid Apps** agreement must be
active first.

**Apps → Animal Pairs → Monetization → Subscriptions**

| Field | Value |
| --- | --- |
| Subscription group reference name | **Animal Pairs Plus** |
| Group display name (English, U.S.) | **Animal Pairs Plus** |
| Subscription reference name | **Animal Pairs Plus Monthly** |
| Product ID | **`<your bundle ID>.plus.monthly`** (must equal `AP_PLUS_PRODUCT_ID`) |
| Subscription duration | **1 month** |
| Price | **USD 1.99** for the United States, with Apple's equalized prices for the other storefronts. The app shows StoreKit's localized price and never hard-codes it |
| Availability | all countries or regions where the app is sold (the app is English only) |
| Family Sharing | **Off** (matches `Config/Products.storekit`) |
| Localization: English (U.S.), display name | **Animal Pairs Plus** |
| Localization: English (U.S.), description | **More card counts and Exact Pose mode, renewed monthly.** (54 characters; the limit is 55) |
| Introductory offers / promotional offers | none |
| Review screenshot | Parents → **Animal Pairs Plus** section on iPhone, showing the price, the Subscribe button and the renewal terms. Take it from a simulator run with the local StoreKit file, or from a sandbox build |
| Review notes | see below |

Submit the subscription **together with the app version**: a first
subscription is reviewed with a new build. On the version page, under
*In-App Purchases and Subscriptions*, add **Animal Pairs Plus Monthly**.

Also check these on the app's version page:

* the Privacy Policy URL is set;
* the Terms of Use link is in the App Description, or a custom EULA is set;
* App Privacy says no data is collected (no accounts, analytics or ads);
* if you choose the Kids category, the adult gate below covers every purchase
  and external link.

## App Review notes (paste into "Notes" for the version and the subscription)

```
Animal Pairs is free to play: Classic mode with 6 cards. An optional monthly
auto-renewable subscription, "Animal Pairs Plus", adds the 12, 16 and 20 card
boards, Exact Pose mode and 70 more animal pictures. There are no ads and no
accounts.

Parental gate: every purchase, Restore Purchases, Manage Subscription and
external link (Terms of Use, Privacy Policy, Support) is behind an adult gate.
On the Home screen tap the gear button (top corner, "Parents and settings").
The gate asks a multiplication question written in words (for example "What
is seven times eight?"); enter the answer on the number pad and tap Check.

Purchase screen: after the gate, the Parents screen opens. The "Animal Pairs
Plus" section lists what is included, the price and period from the App Store,
the auto-renewal and cancellation terms, Subscribe, Restore Purchases, Manage
Subscription, Redeem Offer Code, Terms of Use and Privacy Policy.

Locked features: from Home, tap Play to reach the board choice. The 12, 16 and
20 card boards and Exact Pose show a lock. Tapping one shows a short message
for the child with an "Ask a grown-up" button, which opens the same parental
gate. A child can never start a purchase from there.

Restore: Parents → Animal Pairs Plus → Restore Purchases. A message confirms
that the subscription was restored, or that none was found for this Apple
Account.
```

## Release checklist

- [ ] Final bundle ID set, product ID set in both places, tests pass in Xcode
- [ ] Terms of Use, Privacy Policy and Support URLs set and opened on a device
- [ ] Build and test on an iPhone and an iPad simulator (`xcodebuild … build test`, see README)
- [ ] Sandbox check with a sandbox Apple Account: subscribe, cancel in Manage Subscription, expiry, Restore on a second device
- [ ] Subscription created as above, with a review screenshot; attached to the version
- [ ] App Store screenshots, description and marketing text (still missing; see ASSET_CHECKLIST)
- [ ] Release signing and a TestFlight round before submitting
