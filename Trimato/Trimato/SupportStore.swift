import Combine
import Foundation
import StoreKit

@MainActor
final class SupportStore: ObservableObject {
    struct Option: Identifiable {
        let id: String
        let name: String
    }

    struct ThankYou: Codable, Equatable {
        let transactionID: UInt64
        let productID: String
        let name: String
        let date: Date

        var message: String { "Thank you for supporting Trimato with \(name)." }
    }

    struct PurchaseError: Identifiable {
        let id = UUID()
        let message: String
    }

    static func applicationStore() -> SupportStore {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-trimato-support-ui-tests") {
            let defaults = UserDefaults(suiteName: "TrimatoSupportUITests")!
            defaults.removePersistentDomain(forName: "TrimatoSupportUITests")
            return SupportStore(defaults: defaults)
        }
        // Hosted unit tests create their own store and must own their test transactions.
        return SupportStore(listensForTransactions: NSClassFromString("XCTestCase") == nil)
#else
        return SupportStore()
#endif
    }

    static let options = [
        Option(id: "com.marconius.trimato.support.littleSlice", name: "A little slice"),
        Option(id: "com.marconius.trimato.support.juicyCut", name: "A juicy cut"),
        Option(id: "com.marconius.trimato.support.freshTake", name: "A fresh take"),
        Option(id: "com.marconius.trimato.support.wholeTomato", name: "The whole tomato")
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var pendingProductIDs: Set<String> = []
    var pending: Bool { !pendingProductIDs.isEmpty }
    @Published private(set) var loadFailed = false
    @Published private(set) var latestThankYou: ThankYou?
    @Published var purchaseError: PurchaseError?

    private let defaults: UserDefaults
    private var listener: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private static let historyKey = "trimato.support.history"
    private var history: [ThankYou]

    init(defaults: UserDefaults = .standard, listensForTransactions: Bool = true) {
        self.defaults = defaults
        history = defaults.data(forKey: Self.historyKey).flatMap {
            try? JSONDecoder().decode([ThankYou].self, from: $0)
        } ?? []
        latestThankYou = history.max { $0.date < $1.date }
        if listensForTransactions {
            listener = Task { [weak self] in
                for await result in Transaction.updates {
                    guard let self else { return }
                    await self.process(result)
                }
            }
            recovery = Task { [weak self] in
                await self?.refreshUnfinishedTransactions()
            }
        }
    }

    deinit {
        listener?.cancel()
        recovery?.cancel()
    }

    func product(for option: Option) -> Product? {
        products.first { $0.id == option.id }
    }

    func loadProducts() async {
        guard !isLoading, !isPurchasing else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: Self.options.map(\.id))
            products = Self.options.compactMap { option in
                loaded.first { $0.id == option.id && $0.type == .consumable }
            }
            loadFailed = products.count != Self.options.count
        } catch {
            products = []
            loadFailed = true
        }
    }

    func purchase(
        _ product: Product,
        using action: @MainActor (Product) async throws -> Product.PurchaseResult = { try await $0.purchase() }
    ) async {
        guard !isPurchasing, !isLoading,
              Self.options.contains(where: { $0.id == product.id }),
              product.type == .consumable else { return }
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
        do {
            switch try await action(product) {
            case .success(let result):
                await process(result)
            case .pending:
                pendingProductIDs.insert(product.id)
            case .userCancelled:
                break
            @unknown default:
                purchaseError = PurchaseError(message: "The purchase result could not be read. Check your purchase history in the App Store.")
            }
        } catch StoreKitError.userCancelled {
            // Cancellation requires no error or purchase confirmation.
        } catch {
            // A failure to receive a result is not proof that no payment occurred.
            purchaseError = PurchaseError(message: "The purchase could not be completed. Check your App Store connection and purchase history before trying again.")
        }
    }

    func refreshUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            await process(result)
        }
    }

    private func process(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard Self.options.contains(where: { $0.id == transaction.productID }),
                  transaction.productType == .consumable else { return }
            guard transaction.revocationDate == nil else {
                history.removeAll { $0.transactionID == transaction.id }
                saveHistory()
                latestThankYou = history.max { $0.date < $1.date }
                await transaction.finish()
                return
            }
            let name = products.first { $0.id == transaction.productID }?.displayName
                ?? Self.options.first { $0.id == transaction.productID }!.name
            recordSupport(id: transaction.id, productID: transaction.productID,
                          name: name, date: transaction.purchaseDate)
            await transaction.finish()
            pendingProductIDs.remove(transaction.productID)
        case .unverified(let transaction, _):
            guard Self.options.contains(where: { $0.id == transaction.productID }) else { return }
            purchaseError = PurchaseError(message: "The App Store purchase could not be verified. Check your purchase history in the App Store before trying again.")
        }
    }

    // Persist before finishing; redelivery must not record the same tip twice.
    @discardableResult
    func recordSupport(id: UInt64, productID: String, name: String, date: Date) -> Bool {
        guard Self.options.contains(where: { $0.id == productID }),
              !history.contains(where: { $0.transactionID == id }) else { return false }
        let thankYou = ThankYou(transactionID: id, productID: productID, name: name, date: date)
        history.append(thankYou)
        saveHistory()
        latestThankYou = history.max { $0.date < $1.date }
        return true
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }
}
