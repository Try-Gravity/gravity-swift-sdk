import XCTest
@testable import GravitySDK

final class ConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ConsentTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testNoCMPKeysReturnsNil() {
        XCTAssertNil(ConsentSignal.fromCMP(defaults))
    }

    func testReadsTCFStringAndGdprApplies() {
        defaults.set("CPtest.consent", forKey: "IABTCF_TCString")
        defaults.set(1, forKey: "IABTCF_gdprApplies")

        let consent = ConsentSignal.fromCMP(defaults)
        XCTAssertEqual(consent?.tcfString, "CPtest.consent")
        XCTAssertEqual(consent?.gdprApplies, true)
        XCTAssertNil(consent?.usPrivacy)
    }

    func testGdprDoesNotApply() {
        defaults.set(0, forKey: "IABTCF_gdprApplies")

        let consent = ConsentSignal.fromCMP(defaults)
        XCTAssertEqual(consent?.gdprApplies, false)
        XCTAssertNil(consent?.tcfString)
    }

    func testReadsUSPrivacyString() {
        defaults.set("1YNN", forKey: "IABUSPrivacy_String")

        let consent = ConsentSignal.fromCMP(defaults)
        XCTAssertEqual(consent?.usPrivacy, "1YNN")
        XCTAssertNil(consent?.gdprApplies)
    }

    func testEmptyStringsTreatedAsAbsent() {
        defaults.set("", forKey: "IABTCF_TCString")
        defaults.set("", forKey: "IABUSPrivacy_String")

        XCTAssertNil(ConsentSignal.fromCMP(defaults))
    }

    func testToDictOmitsAbsentFields() {
        let dict = ConsentSignal(gdprApplies: true, tcfString: "CPabc").toDict()
        XCTAssertEqual(dict["gdprApplies"] as? Bool, true)
        XCTAssertEqual(dict["tcfString"] as? String, "CPabc")
        XCTAssertNil(dict["usPrivacy"])
    }

    func testToDictEmptyWhenNoFields() {
        XCTAssertTrue(ConsentSignal().toDict().isEmpty)
    }

    /// `readCMPConsent: false` must keep CMP storage out of requests entirely;
    /// an explicit `consent:` argument is still sent.
    func testReadCMPConsentOptOut() {
        let standard = UserDefaults.standard
        standard.set("CPopt.out", forKey: "IABTCF_TCString")
        defer { standard.removeObject(forKey: "IABTCF_TCString") }

        func body(_ gravity: Gravity, consent: ConsentSignal? = nil) -> [String: Any] {
            gravity.buildRequestBody(
                messages: [Message(role: "user", content: "hi")],
                sessionId: "s", userId: "u", placements: [.belowResponse()],
                userIP: nil, hashedIdentity: nil, extraUserFields: nil,
                extraDeviceFields: nil, production: nil, relevancy: nil,
                consent: consent
            )
        }

        // honorATT: false keeps the host process's real ATT status (varies by
        // test platform) out of these CMP-focused assertions.
        let onByDefault = body(Gravity(apiKey: "k", honorATT: false))
        XCTAssertEqual((onByDefault["consent"] as? [String: Any])?["tcfString"] as? String, "CPopt.out")

        let optedOut = body(Gravity(apiKey: "k", readCMPConsent: false, honorATT: false))
        XCTAssertNil(optedOut["consent"])

        let explicit = body(
            Gravity(apiKey: "k", readCMPConsent: false, honorATT: false),
            consent: ConsentSignal(usPrivacy: "1YNN")
        )
        XCTAssertEqual((explicit["consent"] as? [String: Any])?["usPrivacy"] as? String, "1YNN")
    }

    func testReadsGPPStringAndSectionIds() {
        defaults.set("DBABMA~CPtest", forKey: "IABGPP_HDR_GppString")
        defaults.set("7_8", forKey: "IABGPP_GppSID")

        let consent = ConsentSignal.fromCMP(defaults)
        XCTAssertEqual(consent?.gpp, "DBABMA~CPtest")
        XCTAssertEqual(consent?.gppSid, [7, 8])
        XCTAssertNil(consent?.tcfString)
    }

    func testUnreadableGPPSectionIdsAreDropped() {
        defaults.set("DBABMA~CPtest", forKey: "IABGPP_HDR_GppString")
        defaults.set("7_x", forKey: "IABGPP_GppSID")

        let consent = ConsentSignal.fromCMP(defaults)
        XCTAssertEqual(consent?.gpp, "DBABMA~CPtest")
        XCTAssertNil(consent?.gppSid)
    }

    func testGPPSectionIdsAloneReturnNil() {
        defaults.set("", forKey: "IABGPP_HDR_GppString")
        defaults.set("7", forKey: "IABGPP_GppSID")

        XCTAssertNil(ConsentSignal.fromCMP(defaults))
    }

    func testToDictIncludesGpp() {
        let dict = ConsentSignal(gpp: "DBABMA~CPtest", gppSid: [7, 8]).toDict()
        XCTAssertEqual(dict["gpp"] as? String, "DBABMA~CPtest")
        XCTAssertEqual(dict["gppSid"] as? [Int], [7, 8])
        XCTAssertNil(ConsentSignal().toDict()["gpp"])
        XCTAssertNil(ConsentSignal().toDict()["gppSid"])
    }

    func testRequestBodyCarriesGPPAndExplicitValuesWin() {
        let standard = UserDefaults.standard
        standard.set("DBABMA~CPcmp", forKey: "IABGPP_HDR_GppString")
        standard.set("7", forKey: "IABGPP_GppSID")
        defer {
            standard.removeObject(forKey: "IABGPP_HDR_GppString")
            standard.removeObject(forKey: "IABGPP_GppSID")
        }

        func consent(_ explicit: ConsentSignal?) -> [String: Any]? {
            Gravity(apiKey: "k", honorATT: false).buildRequestBody(
                messages: [Message(role: "user", content: "hi")],
                sessionId: "s", userId: "u", placements: [.belowResponse()],
                userIP: nil, hashedIdentity: nil, extraUserFields: nil,
                extraDeviceFields: nil, production: nil, relevancy: nil,
                consent: explicit
            )["consent"] as? [String: Any]
        }

        let fromCMP = consent(nil)
        XCTAssertEqual(fromCMP?["gpp"] as? String, "DBABMA~CPcmp")
        XCTAssertEqual(fromCMP?["gppSid"] as? [Int], [7])

        let explicit = consent(ConsentSignal(gpc: true, gpp: "DBABMA~CPapp", gppSid: [8]))
        XCTAssertEqual(explicit?["gpp"] as? String, "DBABMA~CPapp")
        XCTAssertEqual(explicit?["gppSid"] as? [Int], [8])
        XCTAssertEqual(explicit?["gpc"] as? Bool, true)
    }

    func testMergingAttOptOutKeepsGpp() {
        let merged = ConsentSignal.merging(
            ConsentSignal(gpp: "DBABMA~CPtest", gppSid: [7]), attOptsOut: true
        )
        XCTAssertEqual(merged?.gpc, true)
        XCTAssertEqual(merged?.gpp, "DBABMA~CPtest")
        XCTAssertEqual(merged?.gppSid, [7])
    }

    func testToDictIncludesGpc() {
        let dict = ConsentSignal(gpc: true).toDict()
        XCTAssertEqual(dict["gpc"] as? Bool, true)
        XCTAssertNil(ConsentSignal().toDict()["gpc"])
    }

    func testMergingAttOptOutAssertsGpc() {
        // Opt-out with no other signal creates one carrying only gpc.
        let created = ConsentSignal.merging(nil, attOptsOut: true)
        XCTAssertEqual(created?.gpc, true)
        XCTAssertNil(created?.tcfString)

        // Opt-out merges into an existing CMP signal without dropping it.
        let merged = ConsentSignal.merging(
            ConsentSignal(usPrivacy: "1YNN"), attOptsOut: true
        )
        XCTAssertEqual(merged?.gpc, true)
        XCTAssertEqual(merged?.usPrivacy, "1YNN")

        // Authorized tracking / no ATT signal leaves the input untouched —
        // it must never unset an opt-out the publisher already sent.
        XCTAssertNil(ConsentSignal.merging(nil, attOptsOut: false))
        XCTAssertNil(ConsentSignal.merging(nil, attOptsOut: nil))
        let preserved = ConsentSignal.merging(
            ConsentSignal(gpc: true), attOptsOut: false
        )
        XCTAssertEqual(preserved?.gpc, true)
    }
}
