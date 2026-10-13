import Combine
import Foundation
import OSLog
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

    struct PurchaseNotice: Identifiable {
        enum Result {
            case thankYou(ThankYou)
            case pending(productID: String, name: String)
            case failure(String)
        }

        let id = UUID()
        let result: Result

        var title: String {
            switch result {
            case .thankYou: "Thank you"
            case .pending: "Purchase pending"
            case .failure: "Support purchase"
            }
        }

        var message: String {
            switch result {
            case .thankYou(let thankYou): thankYou.message
            case .pending(_, let name): "The purchase of \(name) is pending. Complete any approval or payment request from the App Store."
            case .failure(let message): message
            }
        }
    }

    static func applicationStore() -> SupportStore {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-trimato-support-ui-tests") {
            let defaults = UserDefaults(suiteName: "TrimatoSupportUITests")!
            defaults.removePersistentDomain(forName: "TrimatoSupportUITests")
            return SupportStore(defaults: defaults)
        }
        // Only an explicitly configured hosted test may suppress the app's listener.
        let hostedTest = ProcessInfo.processInfo.environment["TRIMATO_SUPPORT_HOSTED_UNIT_TESTS"] == "1"
        return SupportStore(listensForTransactions: !hostedTest)
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
    @Published private(set) var purchaseNotice: PurchaseNotice?
    @Published private(set) var isNoticePresented = false

    private let defaults: UserDefaults
    private var listener: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private static let historyKey = "trimato.support.history"
    private var history: [ThankYou]
    private var notices: [PurchaseNotice] = []
    private var processingIDs: Set<UInt64> = []
    private var presentationActive = false
    private var noticeIsDismissing = false
    private static let logger = Logger(subsystem: "com.marconius.trimato", category: "SupportPurchases")

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
                    await self.process(result, source: "Transaction.updates")
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
            if loadFailed {
#if DEBUG
                let missing = Self.options.map(\.id).filter { id in !products.contains { $0.id == id } }
                Self.logger.error("StoreKit returned no consumable product for: \(missing.joined(separator: ", "), privacy: .public)")
#endif
            }
        } catch {
            log(error, operation: "Loading products")
            products = []
            loadFailed = true
        }
    }

    func purchase(
        _ product: Product,
        using action: @MainActor (Product) async throws -> Product.PurchaseResult = { try await $0.purchase() }
    ) async {
        guard !isPurchasing, !isLoading, purchaseNotice == nil, !noticeIsDismissing,
              Self.options.contains(where: { $0.id == product.id }),
              product.type == .consumable else { return }
        isPurchasing = true
        trace("Starting purchase: \(product.id)")
        purchaseError = nil
        let recordedIDs = Set(history.map(\.transactionID))
        defer {
            isPurchasing = false
            presentNextNotice()
        }
        do {
            switch try await action(product) {
            case .success(let result):
                trace("Purchase returned success: \(product.id)")
                await process(result, source: "purchase result")
            case .pending:
                trace("Purchase returned pending: \(product.id)")
                // A verified update may arrive before the purchase call returns pending.
                if !history.contains(where: { $0.productID == product.id && !recordedIDs.contains($0.transactionID) }) {
                    pendingProductIDs.insert(product.id)
                    await refreshUnfinishedTransactions()
                    if pendingProductIDs.contains(product.id) {
                        enqueue(PurchaseNotice(result: .pending(productID: product.id, name: product.displayName)))
                    }
                }
            case .userCancelled:
                trace("Purchase returned cancellation: \(product.id)")
                break
            @unknown default:
                reportError("The purchase result could not be read. Check your purchase history in the App Store.")
            }
        } catch StoreKitError.userCancelled {
            // Cancellation requires no error or purchase confirmation.
        } catch {
            log(error, operation: "Purchasing support")
            // A failure to receive a result is not proof that no payment occurred.
            reportError("The purchase could not be completed. Check your App Store connection and purchase history before trying again.")
        }
    }

    func refreshUnfinishedTransactions() async {
        trace("Checking Transaction.unfinished")
        for await result in Transaction.unfinished {
            await process(result, source: "Transaction.unfinished")
        }
    }

    private func process(_ result: VerificationResult<Transaction>, source: String) async {
        switch result {
        case .verified(let transaction):
            guard Self.options.contains(where: { $0.id == transaction.productID }),
                  transaction.productType == .consumable else { return }
            trace("Verified transaction from \(source): \(transaction.productID)")
            guard processingIDs.insert(transaction.id).inserted else { return }
            defer { processingIDs.remove(transaction.id) }
            pendingProductIDs.remove(transaction.productID)
            guard transaction.revocationDate == nil else {
                history.removeAll { $0.transactionID == transaction.id }
                saveHistory()
                latestThankYou = history.max { $0.date < $1.date }
                await transaction.finish()
                return
            }
            let name = products.first { $0.id == transaction.productID }?.displayName
                ?? Self.options.first { $0.id == transaction.productID }!.name
            let isNew = recordSupport(id: transaction.id, productID: transaction.productID,
                          name: name, date: transaction.purchaseDate)
            await transaction.finish()
            if isNew, let thankYou = history.first(where: { $0.transactionID == transaction.id }) {
                enqueue(PurchaseNotice(result: .thankYou(thankYou)))
            }
        case .unverified(let transaction, let error):
            guard Self.options.contains(where: { $0.id == transaction.productID }) else { return }
            pendingProductIDs.remove(transaction.productID)
            log(error, operation: "Verifying support")
            reportError("The App Store purchase could not be verified. Check your purchase history in the App Store before trying again.",
                        resolvingPendingProductID: transaction.productID)
        }
    }

    func dismissPurchaseNotice() {
        guard purchaseNotice != nil, !noticeIsDismissing else { return }
        // Retain the content until SwiftUI finishes dismissing its native sheet.
        noticeIsDismissing = true
        isNoticePresented = false
        trace("Dismissing purchase result sheet")
    }

    func purchaseNoticeDidDismiss() {
        if let notice = purchaseNotice, case .failure = notice.result {
            purchaseError = nil
        }
        purchaseNotice = nil
        isNoticePresented = false
        noticeIsDismissing = false
        trace("Purchase result sheet dismissed")
        presentNextNotice()
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        trace("Support presentation active: \(active)")
        if active { presentNextNotice() }
    }

    func presentNextNotice() {
        guard presentationActive, !isPurchasing, !noticeIsDismissing,
              purchaseNotice == nil, !notices.isEmpty else { return }
        purchaseNotice = notices.removeFirst()
        isNoticePresented = true
        trace("Presenting purchase result sheet: \(purchaseNotice!.title)")
    }

    private func enqueue(_ notice: PurchaseNotice, resolvingPendingProductID: String? = nil) {
        let completedProductID: String?
        if case .thankYou(let thankYou) = notice.result {
            completedProductID = thankYou.productID
        } else {
            completedProductID = resolvingPendingProductID
        }
        if let completedProductID {
            notices.removeAll {
                if case .pending(let id, _) = $0.result { return id == completedProductID }
                return false
            }
            if let current = purchaseNotice,
               case .pending(let id, _) = current.result, id == completedProductID {
                notices.insert(notice, at: 0)
                // A completed result gets a new native presentation after pending closes.
                dismissPurchaseNotice()
                return
            }
        }
        notices.append(notice)
        presentNextNotice()
    }

    private func reportError(_ message: String, resolvingPendingProductID: String? = nil) {
        purchaseError = PurchaseError(message: message)
        if let current = purchaseNotice, case .failure(let text) = current.result, text == message { return }
        if notices.contains(where: {
            if case .failure(let text) = $0.result { return text == message }
            return false
        }) { return }
        enqueue(PurchaseNotice(result: .failure(message)), resolvingPendingProductID: resolvingPendingProductID)
    }

    private func log(_ error: Error, operation: String) {
#if DEBUG
        let detail = error as NSError
        Self.logger.error("\(operation, privacy: .public) failed: \(detail.domain, privacy: .public), code \(detail.code)")
        if let underlying = detail.userInfo[NSUnderlyingErrorKey] as? NSError {
            Self.logger.error("Underlying StoreKit error: \(underlying.domain, privacy: .public), code \(underlying.code)")
        }
#endif
    }

    private func trace(_ message: String) {
#if DEBUG
        Self.logger.debug("\(message, privacy: .public)")
#endif
    }

    // Persist before finishing; redelivery must not record the same purchase twice.
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
