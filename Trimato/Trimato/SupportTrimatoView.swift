import StoreKit
import SwiftUI

struct SupportTrimatoView: View {
    @Environment(\.purchase) private var purchase
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: SupportStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Support Trimato")
                .font(.title)
            if let thankYou = store.latestThankYou {
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
                Text("Purchase awaiting App Store approval.")
            }
            ForEach(SupportStore.options) { option in
                if let product = store.product(for: option) {
                    Button {
                        Task { await store.purchase(product) { try await purchase($0) } }
                    } label: {
                        HStack {
                            Text(product.displayName)
                            Spacer()
                            Text(product.displayPrice)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(store.isPurchasing || store.isLoading)
                    .accessibilityIdentifier(option.id)
                }
            }
            if store.loadFailed {
                Text("Support options could not be loaded. Check your App Store connection, then choose Retry.")
                Button("Retry") { Task { await store.loadProducts() } }
                    .disabled(store.isLoading || store.isPurchasing)
            }
            HStack {
                Spacer()
                ContextualHelpButton(topic: .support)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(28)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .editorAppearance()
        .background(EditorTheme.controlSurface)
        .task {
            await store.loadProducts()
            await store.refreshUnfinishedTransactions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshUnfinishedTransactions() }
            }
        }
        .sheet(item: $store.purchaseError) { error in
            VStack(alignment: .leading, spacing: 20) {
                Text("Support purchase").font(.title2)
                Text(error.message).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("OK") { store.purchaseError = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 430)
        }
    }
}
