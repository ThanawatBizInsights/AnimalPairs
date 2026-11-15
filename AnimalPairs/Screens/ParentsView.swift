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

    private var purchaseSection: some View {
        let t = model.localizer
        let purchases = model.purchases
        return Section {
            if purchases.isUnlocked {
                Label(t["parents.unlock.owned"], systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Palette.mintDeep)
                    .font(.rounded(.headline))
            } else {
                Text(t["parents.unlock.includes"]).font(.rounded(.body))
                if let product = purchases.product {
                    Button {
                        Task { await purchases.purchase(using: purchaseAction) }
                    } label: {
                        Text(t("parents.unlock.buy", product.displayPrice))
                    }
                    .buttonStyle(PillowButtonStyle(kind: .primary))
                    .disabled(purchases.flowState == .purchasing || purchases.flowState == .restoring)
                } else if purchases.flowState == .loadingProducts {
                    ProgressView(t["parents.unlock.loading"])
                } else {
                    Text(t("parents.unlock.unavailable", purchases.productID))
                        .font(.rounded(.callout))
                        .foregroundStyle(Palette.brownSoft)
                    Button(t["parents.unlock.retry"]) { Task { await purchases.loadProduct() } }
                        .frame(minHeight: 44)
                }
            }
            Button {
                Task { await purchases.restore() }
            } label: {
                Label(t["parents.restore"], systemImage: "arrow.clockwise")
            }
            .frame(minHeight: 44)
            .disabled(purchases.flowState == .purchasing || purchases.flowState == .restoring)

            if let message = flowMessage(purchases.flowState) {
                Text(message).font(.rounded(.callout)).foregroundStyle(Palette.brown)
            }
        } header: {
            Text(t["parents.unlock.title"])
        } footer: {
            if model.configuration.usesPlaceholderProductID {
                Text(t["parents.unlock.placeholderID"])
            }
        }
    }

    private var settingsSection: some View {
        let t = model.localizer
        return Section(t["parents.settings"]) {
            Toggle(t["parents.sound"], isOn: Binding(get: { model.settings.soundEnabled },
                                                       set: { model.setSoundEnabled($0) }))
                .frame(minHeight: 44)
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
            Toggle(isOn: $purchases.debugMockUnlocked) { Text(verbatim: "Simulate full unlock (mock)") }
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
        case .purchasing: return t["purchase.purchasing"]
        case .purchased: return t["purchase.success"]
        case .pendingApproval: return t["purchase.pending"]
        case .cancelled: return t["purchase.cancelled"]
        case .verificationFailed: return t["purchase.verificationFailed"]
        case .restoring: return t["purchase.restoring"]
        case .restoreFoundNothing: return t["purchase.restoreNothing"]
        case .restored: return t["purchase.restored"]
        case .failed(let detail): return t("purchase.failed", detail)
        }
    }

    private func loadProgress() {
        records = (try? model.history.recentRecords()) ?? []
        totals = (try? model.history.totals()) ?? ProgressTotals()
    }
}
