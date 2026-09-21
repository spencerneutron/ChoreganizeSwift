//
//  EntitlementTests.swift
//  ChoreganizeTests
//
//  CG-12 / #95 — the pure Plus-entitlement decision. StoreKit's transaction
//  machinery itself is exercised via the .storekit configuration in-sim and by
//  sandbox purchases at the release gate; here we pin the product catalog and
//  the ID→entitlement rule so a catalog typo or an accidental ID change can't
//  ship silently.
//

import Testing
import Foundation
@testable import Choreganize

struct EntitlementTests {

    @Test func anyPlusProductUnlocks() {
        #expect(PlusProduct.isEntitled(activeProductIDs: [PlusProduct.yearly]))
        #expect(PlusProduct.isEntitled(activeProductIDs: [PlusProduct.lifetime]))
    }

    @Test func retiredMonthlyProductDoesNotUnlock() {
        // Pricing decision 2026-09-20: yearly + lifetime only. The monthly ID was
        // never created in ASC; keep it out of the catalog so a stray transaction
        // for it (sandbox leftovers) can't unlock Plus.
        #expect(!PlusProduct.isEntitled(activeProductIDs: ["com.svk.Choreganize.plus.monthly"]))
    }

    @Test func plusUnlocksAlongsideUnrelatedProducts() {
        #expect(PlusProduct.isEntitled(activeProductIDs: ["com.other.thing", PlusProduct.yearly]))
    }

    @Test func unknownOrEmptyProductsDoNotUnlock() {
        #expect(!PlusProduct.isEntitled(activeProductIDs: []))
        #expect(!PlusProduct.isEntitled(activeProductIDs: ["com.svk.Choreganize.plus.weekly"]))
        #expect(!PlusProduct.isEntitled(activeProductIDs: ["com.other.thing"]))
    }

    @Test func catalogMatchesAppStoreConnectIDs() {
        // These literals must match the products configured in ASC (and
        // Configuration.storekit). Changing one is a release decision.
        #expect(PlusProduct.all == [
            "com.svk.Choreganize.plus.yearly",
            "com.svk.Choreganize.plus.lifetime",
        ])
    }
}
