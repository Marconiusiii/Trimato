import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import Trimato

@MainActor
final class SupportStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "SupportTrimato")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        suite = "TrimatoSupportTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        session.resetToDefaultState()
        session.clearTransactions()
        defaults.removePersistentDomain(forName: suite)
        session = nil
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for StoreKit processing")
    }

    func testRepeatedConsumablePurchasesPersistAndFinish() async throws {
        let store = SupportStore(defaults: defaults)
        await store.loadProducts()
        XCTAssertEqual(store.products.count, 4)
        XCTAssertFalse(store.loadFailed)
        let product = try XCTUnwrap(store.products.first)
        await store.purchase(product)
        let first = try XCTUnwrap(store.latestThankYou)
        XCTAssertFalse(store.isPurchasing)
        XCTAssertNil(store.purchaseError)
        XCTAssertEqual(first.message, "Thank you for supporting Trimato with A little slice.")
        let firstNotice = try XCTUnwrap(store.purchaseNotice)
        guard case .thankYou(let confirmedFirst) = firstNotice.result else {
            return XCTFail("A verified purchase must present a confirmation")
        }
        XCTAssertEqual(confirmedFirst.transactionID, first.transactionID)
        store.dismissPurchaseNotice()
        await store.purchase(product)
        let second = try XCTUnwrap(store.latestThankYou)
        XCTAssertNotEqual(first.transactionID, second.transactionID)
        let secondNotice = try XCTUnwrap(store.purchaseNotice)
        guard case .thankYou(let confirmedSecond) = secondNotice.result else {
            return XCTFail("A repeated support purchase must present its own confirmation")
        }
        XCTAssertEqual(confirmedSecond.transactionID, second.transactionID)
        let reopened = SupportStore(defaults: defaults, listensForTransactions: false)
        XCTAssertEqual(reopened.latestThankYou, second)
        XCTAssertNil(reopened.purchaseNotice, "Saved history must not repeat a confirmation")
        var unfinishedIDs: [UInt64] = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result { unfinishedIDs.append(transaction.id) }
        }
        XCTAssertFalse(unfinishedIDs.contains(first.transactionID))
        XCTAssertFalse(unfinishedIDs.contains(second.transactionID))
    }

    func testPendingApprovalPresentsConfirmationThroughTransactionUpdates() async throws {
        session.askToBuyEnabled = true
        let store = SupportStore(defaults: defaults)
        await store.loadProducts()
        let product = try XCTUnwrap(store.products.first)
        await store.purchase(product)
        XCTAssertTrue(store.pending)
        XCTAssertNil(store.latestThankYou)
        XCTAssertFalse(store.isPurchasing)
        let notice = try XCTUnwrap(store.purchaseNotice)
        guard case .pending(let productID, _) = notice.result else {
            return XCTFail("Pending purchases must have a native result presentation")
        }
        XCTAssertEqual(productID, product.id)
        let pending = try XCTUnwrap(session.allTransactions().first(where: { $0.pendingAskToBuyConfirmation }))
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        // Transaction updates must resolve the open window without forcing recovery.
        try await waitUntil { store.latestThankYou != nil && store.purchaseNotice?.title == "Thank you" }
        XCTAssertFalse(store.pending)
        XCTAssertNil(store.purchaseError)
    }

    func testPurchaseFailureDoesNotCreateThankYouAndAllowsRetry() async throws {
        let store = SupportStore(defaults: defaults)
        await store.loadProducts()
        let product = try XCTUnwrap(store.products.first)
        try await session.setSimulatedError(.generic(.notAvailableInStorefront), forAPI: .purchase)
        await store.purchase(product)
        XCTAssertNil(store.latestThankYou)
        XCTAssertNotNil(store.purchaseError)
        XCTAssertFalse(store.isPurchasing)
        store.dismissPurchaseNotice()
        try await session.setSimulatedError(nil, forAPI: .purchase)
        await store.purchase(product)
        XCTAssertNotNil(store.latestThankYou)
        XCTAssertNil(store.purchaseError)
    }

    func testCancelledPurchaseKeepsPreviousThankYouAndReturnsReady() async throws {
        let store = SupportStore(defaults: defaults)
        await store.loadProducts()
        let product = try XCTUnwrap(store.products.first)
        await store.purchase(product)
        let previous = try XCTUnwrap(store.latestThankYou)
        store.dismissPurchaseNotice()
        await store.purchase(product, using: { _ in .userCancelled })
        XCTAssertEqual(store.latestThankYou, previous)
        XCTAssertNil(store.purchaseError)
        XCTAssertFalse(store.isPurchasing)
        XCTAssertNil(store.purchaseNotice)
    }

    func testProductLoadFailureCanBeRetried() async throws {
        let store = SupportStore(defaults: defaults)
        try await session.setSimulatedError(.generic(.notAvailableInStorefront), forAPI: .loadProducts)
        await store.loadProducts()
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertFalse(store.isLoading)
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        await store.loadProducts()
        XCTAssertEqual(store.products.count, 4)
        XCTAssertFalse(store.loadFailed)
    }

    func testStartupRecoversAnUnfinishedPurchase() async throws {
        let transaction = try await session.buyProduct(identifier: SupportStore.options[1].id)
        let store = SupportStore(defaults: defaults)
        try await waitUntil { store.latestThankYou?.transactionID == transaction.id && store.purchaseNotice?.title == "Thank you" }
        XCTAssertEqual(store.latestThankYou?.productID, SupportStore.options[1].id)
    }

    func testRedeliveryCannotDuplicateOrReplaceLatestThankYouWithOlderPurchase() {
        let store = SupportStore(defaults: defaults, listensForTransactions: false)
        XCTAssertTrue(store.recordSupport(id: 2, productID: SupportStore.options[1].id,
            name: "A juicy cut", date: Date(timeIntervalSince1970: 200)))
        XCTAssertFalse(store.recordSupport(id: 2, productID: SupportStore.options[1].id,
            name: "A juicy cut", date: Date(timeIntervalSince1970: 200)))
        XCTAssertTrue(store.recordSupport(id: 1, productID: SupportStore.options[0].id,
            name: "A little slice", date: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(store.latestThankYou?.transactionID, 2)
        XCTAssertFalse(store.recordSupport(id: 3, productID: "unknown", name: "Unknown", date: .now))
    }
}
