//
//  StoreKitConfigurationTests.swift
//  ChoreganizeTests
//
//  Guards Configuration.storekit two ways, both deterministic across simulator
//  runtimes: Apple's own parser must accept the file (SKTestSession throws on
//  a malformed config), and the catalog the file defines must match
//  PlusProduct exactly. A hand-edited config that Xcode silently rejects would
//  otherwise only surface as an empty paywall.
//
//  Deliberately NOT asserted: Product.products(for:) under the test session —
//  that call returned nothing on an iOS 26.4 simulator while passing on 27.0,
//  so it measured the runtime, not the file.
//

import Testing
import Foundation
import StoreKitTest
@testable import Choreganize

struct StoreKitConfigurationTests {

    private func configurationJSON() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "Configuration", withExtension: "storekit"))
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func appleParserAcceptsTheConfigurationFile() throws {
        let session = try SKTestSession(configurationFileNamed: "Configuration")
        session.disableDialogs = true
    }

    @Test func configuredCatalogMatchesPlusProduct() throws {
        let json = try configurationJSON()
        let oneTime = (json["products"] as? [[String: Any]]) ?? []
        let groups = (json["subscriptionGroups"] as? [[String: Any]]) ?? []
        let subscriptions = groups.flatMap { ($0["subscriptions"] as? [[String: Any]]) ?? [] }

        let ids = Set(oneTime.compactMap { $0["productID"] as? String }
                      + subscriptions.compactMap { $0["productID"] as? String })
        #expect(ids == PlusProduct.all)

        let yearly = subscriptions.first { $0["productID"] as? String == PlusProduct.yearly }
        #expect(yearly?["recurringSubscriptionPeriod"] as? String == "P1Y")
        #expect(yearly?["familyShareable"] as? Bool == true)

        let lifetime = oneTime.first { $0["productID"] as? String == PlusProduct.lifetime }
        #expect(lifetime?["type"] as? String == "NonConsumable")
        #expect(lifetime?["familyShareable"] as? Bool == true)

        // One group, named for the paywall's subscription heading.
        #expect(groups.count == 1)
        #expect(groups.first?["name"] as? String == "Choreganize Plus")
    }
}
