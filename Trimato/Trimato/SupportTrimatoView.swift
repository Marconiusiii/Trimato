import AppKit
import StoreKit
import SwiftUI

private struct SupportCloseActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var closeSupport: (() -> Void)? {
        get { self[SupportCloseActionKey.self] }
        set { self[SupportCloseActionKey.self] = newValue }
    }
}

struct SupportTrimatoView: View {
    @Environment(\.purchase) private var purchase
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var store: SupportStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Support Trimato")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text("If Trimato helps you make the cut, you can support future updates. Any amount is appreciated, and your support is always optional. Thank you for helping Trimato grow!")
                .fixedSize(horizontal: false, vertical: true)
            if let thankYou = store.latestThankYou {
                Text("Thank you")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(thankYou.message)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("trimato.support.thank-you")
            }
            if store.isLoading {
                ProgressView("Loading support options…")
            }
            if store.isPurchasing {
                ProgressView("Completing purchase…")
            }
            if store.pending {
                Text("Purchase pending.")
            }
            Text("Support options")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(SupportStore.options) { option in
                let product = store.product(for: option)
                Button {
                    if let product {
                        Task {
                            await store.purchase(product) { try await purchase($0) }
                            store.setPresentationActive(NSApp.isActive)
                        }
                    }
                } label: {
                    HStack {
                        Text(product?.displayName ?? option.name)
                        Spacer()
                        Text(product?.displayPrice ?? (store.loadFailed ? "Price unavailable" : "Loading price…"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(product == nil || store.isPurchasing || store.isLoading || store.purchaseNotice != nil)
                .accessibilityIdentifier(option.id)
            }
            if store.loadFailed {
                Text("Support options could not be loaded. Check your App Store connection, then choose Retry.")
                Button("Retry") { Task { await store.loadProducts() } }
                    .disabled(store.isLoading || store.isPurchasing)
            }
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isPurchasing)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(28)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .editorAppearance()
        .background(EditorTheme.controlSurface)
        .focusedSceneValue(\.closeSupport, close)
        .task {
            store.setPresentationActive(NSApp.isActive)
            await store.loadProducts()
            await store.refreshUnfinishedTransactions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.setPresentationActive(NSApp.isActive)
            Task { await store.refreshUnfinishedTransactions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            store.setPresentationActive(false)
        }
        .onDisappear { store.setPresentationActive(false) }
        .sheet(isPresented: Binding(
            get: { store.isNoticePresented },
            set: { if !$0 { store.dismissPurchaseNotice() } }
        ), onDismiss: store.purchaseNoticeDidDismiss) {
            SupportPurchaseResultView(store: store)
        }
    }

    private func close() {
        guard !store.isPurchasing else { return }
        if store.purchaseNotice != nil {
            store.dismissPurchaseNotice()
        } else {
            dismissWindow(id: "support-trimato")
        }
    }
}

private struct SupportPurchaseResultView: View {
    @ObservedObject var store: SupportStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let notice = store.purchaseNotice {
                Text(notice.title)
                    .font(.title2)
                    .accessibilityAddTraits(.isHeader)
                Text(notice.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("trimato.support.result-message")
                if case .pending = notice.result {
                    ProgressView("Waiting for purchase completion.")
                }
                HStack {
                    Spacer()
                    switch notice.result {
                    case .thankYou:
                        Button("Done") { store.dismissPurchaseNotice() }
                            .keyboardShortcut(.defaultAction)
                    case .pending, .failure:
                        Button("Close") { store.dismissPurchaseNotice() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 430)
        .onExitCommand { store.dismissPurchaseNotice() }
    }
}
