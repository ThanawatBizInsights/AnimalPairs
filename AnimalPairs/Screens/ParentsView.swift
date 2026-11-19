import AnimalPairsCore
import StoreKit
import SwiftUI

/// Parent-only area: settings, local progress, purchases, privacy, support,
/// reset. Reached only through the parental gate; access expires on leaving,
/// on backgrounding, and after a timeout.
struct ParentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.purchase) private var purchaseAction
    @Environment(\.openURL) private var openURL
    @State private var confirmReset = false
    @State private var records: [CompletionRecord] = []
    @State private var totals = ProgressTotals()

    var body: some View {
        let t = model.localizer
        @Bindable var purchases = model.purchases
        VStack(spacing: 0) {
            HStack {
                Text(t["parents.title"])
                    .font(.rounded(.largeTitle, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(t["parents.done"]) { model.leaveParents() }
                    .buttonStyle(PillowButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            List {
                purchaseSection
                settingsSection
                progressSection
                privacySection
                supportSection
                resetSection
                #if DEBUG
                developerSection
                #endif
                Section {
                    LabeledContent(t["parents.version"], value: model.configuration.appVersion)
                    LabeledContent(t["parents.contentVersion"], value: model.catalog.manifest.manifestVersion)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        // Apple's own offer-code sheet. Apple validates the code; the game is
        // unlocked only when StoreKit then delivers a verified transaction.
        .offerCodeRedemption(isPresented: $purchases.isRedeemSheetPresented) { result in
            Task { await model.purchases.redemptionSheetClosed(result) }
        }
        .onChange(of: purchases.isRedeemSheetPresented) { wasOpen, isOpen in
            // Swiped away without a completion: check all the same.
            if wasOpen && !isOpen {
                Task { await model.purchases.redemptionSheetClosed(.success(())) }
            }
        }
        .task(id: model.historyRevision) { loadProgress() }
        .task {
            // Re-check the access timeout while the area is open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                model.validateParentAccess()
            }
        }
        .confirmationDialog(t["parents.reset.confirmTitle"], isPresented: $confirmReset, titleVisibility: .visible) {
            Button(t["parents.reset.confirm"], role: .destructive) { model.resetProgress() }
            Button(t["common.cancel"], role: .cancel) {}
        } message: {
            Text(t["parents.reset.confirmMessage"])
        }
    }

    // MARK: Sections

    /// Full Game Unlock: a one-time purchase. Shows what it unlocks today,
    /// the localized price from StoreKit, Buy, Restore Purchases, offer codes
    /// and the legal links. Everything here is behind the parental gate.
    private var purchaseSection: some View {
        let t = model.localizer
        let purchases = model.purchases
        let busy = purchases.flowState.isBusy
        let owned = purchases.verifiedLevel == .fullGame
        return Section {
            if owned {
                Label(t["unlock.owned"], systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Palette.mintDeep)
                    .font(.rounded(.headline))
                Text(t["unlock.ownedDetail"]).font(.rounded(.callout))
            } else {
                #if DEBUG
                if purchases.isUnlocked {
                    Text(verbatim: "Debug build: Full Game Unlock is simulated (Developer section). "
                         + "No App Store purchase has been verified.")
                        .font(.rounded(.footnote))
                        .foregroundStyle(Palette.brownSoft)
                }
                #endif
                if purchases.wasRefunded {
                    Label(t["unlock.refunded"], systemImage: "info.circle")
                        .font(.rounded(.callout))
                        .foregroundStyle(Palette.brown)
                }
                Text(t["unlock.free"]).font(.rounded(.body))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(t["unlock.oneTime"])
                    .font(.rounded(.caption, weight: .bold))
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.lavenderMist))
                Text(t["unlock.includes"]).font(.rounded(.headline))
                ForEach(["unlock.feature.classicBoards", "unlock.feature.exactPose", "unlock.feature.pictures"],
                        id: \.self) { key in
                    Label(t[key], systemImage: "checkmark.circle.fill")
                        .font(.rounded(.body))
                        .foregroundStyle(Palette.brown)
                }
                Text(t["unlock.noAds"]).font(.rounded(.footnote)).foregroundStyle(Palette.brownSoft)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if !owned {
                if let product = purchases.product {
                    Text(t("unlock.price", product.displayPrice))
                        .font(.rounded(.title3, weight: .bold))
                    Button {
                        Task { await purchases.purchase(using: purchaseAction) }
                    } label: {
                        Text(t("unlock.buy", product.displayPrice)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillowButtonStyle(kind: .primary))
                    .disabled(busy)
                    .accessibilityHint(Text(t("unlock.buy.hint", product.displayPrice)))
                    Text(t("unlock.terms", product.displayPrice))
                        .font(.rounded(.footnote))
                        .foregroundStyle(Palette.brownSoft)
                } else if purchases.flowState == .loadingProducts {
                    ProgressView(t["parents.unlock.loading"])
                } else {
                    Text(t["parents.unlock.unavailable"])
                        .font(.rounded(.callout))
                        .foregroundStyle(Palette.brownSoft)
                    Button(t["parents.unlock.retry"]) { Task { await purchases.loadProduct() } }
                        .frame(minHeight: 44)
                        .disabled(busy)
                }
            }

            Button {
                Task { await purchases.restore() }
            } label: {
                Label(t["parents.restore"], systemImage: "arrow.clockwise")
            }
            .frame(minHeight: 44)
            .disabled(busy)
            .accessibilityHint(Text(t["parents.restore.hint"]))

            if !owned {
                Button {
                    purchases.beginRedemption()
                } label: {
                    Label(t["parents.redeem"], systemImage: "giftcard")
                }
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityHint(Text(t["parents.redeem.hint"]))
            }

            // Terms of Use is optional for a one-time purchase (Apple's
            // standard licence applies); the link appears once it is set.
            if model.configuration.termsOfUseURL != nil {
                externalLink(title: t["parents.termsOfUse"], url: model.configuration.termsOfUseURL,
                             missingKey: "AP_TERMS_OF_USE_URL")
            }
            externalLink(title: t["parents.privacy.policy"], url: model.configuration.privacyPolicyURL,
                         missingKey: "AP_PRIVACY_POLICY_URL")

            if busy && purchases.flowState != .purchasing {
                ProgressView()
            }
            if let message = flowMessage(purchases.flowState) {
                Text(message).font(.rounded(.callout)).foregroundStyle(Palette.brown)
            }
        } header: {
            Text(t["unlock.title"])
        } footer: {
            Text(t["unlock.footer"])
        }
    }

    private var settingsSection: some View {
        let t = model.localizer
        return Section {
            Toggle(isOn: Binding(get: { model.settings.musicEnabled },
                                 set: { model.setMusicEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t["parents.music"])
                    Text(t[model.hasMusic ? "parents.music.detail" : "parents.music.none"])
                        .font(.rounded(.footnote)).foregroundStyle(Palette.brownSoft)
                }
            }
            .frame(minHeight: 44)
            Toggle(isOn: Binding(get: { model.settings.soundEnabled },
                                 set: { model.setSoundEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t["parents.sound"])
                    Text(t["parents.sound.detail"]).font(.rounded(.footnote)).foregroundStyle(Palette.brownSoft)
                }
            }
            .frame(minHeight: 44)
            Toggle(t["parents.voice"], isOn: Binding(get: { model.settings.voiceEnabled },
                                                       set: { model.setVoiceEnabled($0) }))
                .frame(minHeight: 44)
        } header: {
            Text(t["parents.settings"])
        } footer: {
            Text(t["parents.settings.footer"])
        }
    }

    private var progressSection: some View {
        let t = model.localizer
        return Section {
            LabeledContent(t["parents.progress.rounds"], value: "\(totals.roundsCompleted)")
            LabeledContent(t["parents.progress.pairs"], value: "\(totals.pairsMatched)")
            LabeledContent(t["parents.progress.hints"], value: "\(totals.hintsUsed)")
            if records.isEmpty {
                Text(t["parents.progress.empty"]).foregroundStyle(Palette.brownSoft)
            } else {
                DisclosureGroup(t("parents.progress.recent", records.count)) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(modeName(record.mode)) · \(t("setup.cards", record.boardSize.cardCount))")
                                .font(.rounded(.headline))
                            Text(verbatim: "\(record.completedAt.formatted(.dateTime.locale(t.locale))) · \(t("results.tries", record.attempts)) · \(t("results.hints", record.hintsUsed))")
                                .font(.rounded(.subheadline))
                                .foregroundStyle(Palette.brownSoft)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let warning = model.historyWarning {
                Text(t("parents.progress.warning", warning)).font(.rounded(.footnote))
            }
        } header: {
            Text(t["parents.progress"])
        } footer: {
            Text(t["parents.progress.footer"])
        }
    }

    private var privacySection: some View {
        let t = model.localizer
        return Section(t["parents.privacy"]) {
            Text(t["parents.privacy.summary"]).font(.rounded(.body))
            externalLink(title: t["parents.privacy.policy"], url: model.configuration.privacyPolicyURL,
                         missingKey: "AP_PRIVACY_POLICY_URL")
        }
    }

    private var supportSection: some View {
        let t = model.localizer
        return Section(t["parents.support"]) {
            externalLink(title: t["parents.support.link"], url: model.configuration.supportURL, missingKey: "AP_SUPPORT_URL")
        }
    }

    private var resetSection: some View {
        let t = model.localizer
        return Section {
            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label(t["parents.reset"], systemImage: "trash")
            }
            .frame(minHeight: 44)
        } footer: {
            Text(t["parents.reset.footer"])
        }
    }

    #if DEBUG
    private var developerSection: some View {
        @Bindable var purchases = model.purchases
        let placeholders = model.catalog.manifest.placeholderArtworks.count
        return Section {
            Toggle(isOn: $purchases.debugMockUnlocked) { Text(verbatim: "Simulate Full Game Unlock (mock)") }
            Text(verbatim: "DEBUG builds only. Release builds do not contain this switch. Prefer the Products.storekit configuration for purchase testing.")
                .font(.footnote)
            Text(verbatim: "Artwork: \(placeholders) of \(model.catalog.manifest.artworks.count) are development placeholders. Missing resources: \(model.catalog.missingArtworks.count).")
                .font(.footnote)
            if let notice = model.snapshotNotice { Text(verbatim: "Last snapshot notice: \(notice)").font(.footnote) }
        } header: {
            Text(verbatim: "Developer (debug builds only)")
        }
    }
    #endif

    // MARK: Helpers

    @ViewBuilder
    private func externalLink(title: String, url: URL?, missingKey: String) -> some View {
        let t = model.localizer
        if let url {
            Button {
                openURL(url)
            } label: {
                Label(title, systemImage: "arrow.up.right.square")
            }
            .frame(minHeight: 44)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: "exclamationmark.circle")
                Text(t("parents.link.notConfigured", missingKey))
                    .font(.rounded(.footnote))
                    .foregroundStyle(Palette.brownSoft)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func modeName(_ mode: GameMode) -> String {
        mode == .classic ? model.localizer["mode.classic"] : model.localizer["mode.exactPose"]
    }

    private func flowMessage(_ state: PurchaseFlowState) -> String? {
        let t = model.localizer
        switch state {
        case .idle, .loadingProducts, .productUnavailable: return nil
        case .redeeming: return t["purchase.redeeming"]
        case .checkingRedemption: return t["purchase.checkingRedemption"]
        case .redeemed: return t["purchase.redeemed"]
        case .redeemFoundNothing: return t["purchase.redeemNothing"]
        case .networkUnavailable: return t["purchase.network"]
        case .purchasing: return t["purchase.purchasing"]
        case .purchased: return t["purchase.success"]
        case .pendingApproval: return t["purchase.pending"]
        case .cancelled: return t["purchase.cancelled"]
        case .verificationFailed: return t["purchase.verificationFailed"]
        case .restoring: return t["purchase.restoring"]
        case .restoreFoundNothing: return t["purchase.restoreNothing"]
        case .restoreFoundRefunded: return t["purchase.restoreRefunded"]
        case .restored: return t["purchase.restored"]
        case .failed(let detail): return t("purchase.failed", detail)
        }
    }

    private func loadProgress() {
        records = (try? model.history.recentRecords()) ?? []
        totals = (try? model.history.totals()) ?? ProgressTotals()
    }
}
