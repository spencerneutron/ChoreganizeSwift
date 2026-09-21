//
//  StoreKitConfigurationTests.swift
//  ChoreganizeTests
//
//  Loads Configuration.storekit through Apple's own parser (StoreKitTest) and
//  asserts the catalog it defines matches PlusProduct — a hand-edited config
//  that Xcode silently rejects would otherwise only surface as an empty paywall.
//

import Testing
import StoreKit
import StoreKitTest
@testable import Choreganize

struct StoreKitConfigurationTests {

    @Test func configurationFileParsesAndServesTheCatalog() async throws {
        let session = try SKTestSession(configurationFileNamed: "Configuration")
        session.disableDialogs = true
        session.clearTransactions()
        let products = try await Product.products(for: PlusProduct.all)
        #expect(Set(products.map(\.id)) == PlusProduct.all)
        #expect(products.first { $0.id == PlusProduct.yearly }?.subscription != nil)
        #expect(products.first { $0.id == PlusProduct.lifetime }?.type == .nonConsumable)
    }
}
