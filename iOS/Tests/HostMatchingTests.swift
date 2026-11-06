import Testing
@testable import Annex

struct HostMatchingTests {
    @Test func examplesFromTheDesign() {
        #expect(HostMatching.matches(uriHost: "amazon.de", requestHost: "www.amazon.de"))
        #expect(!HostMatching.matches(uriHost: "login.tum.de", requestHost: "campus.tum.de"))
        #expect(!HostMatching.matches(uriHost: "de", requestHost: "www.amazon.de"))
        #expect(!HostMatching.matches(uriHost: "de", requestHost: "amazon.de"))
    }

    @Test func equalHostsMatch() {
        #expect(HostMatching.matches(uriHost: "www.amazon.de", requestHost: "www.amazon.de"))
        #expect(HostMatching.matches(uriHost: "WWW.Amazon.DE.", requestHost: "www.amazon.de"))
        #expect(HostMatching.matches(uriHost: "localhost", requestHost: "localhost"))
    }

    @Test func childDomainsDontMatchTheirParent() {
        #expect(!HostMatching.matches(uriHost: "www.amazon.de", requestHost: "amazon.de"))
        #expect(!HostMatching.matches(uriHost: "amazon.de", requestHost: "notamazon.de"))
        #expect(!HostMatching.matches(uriHost: "amazon.de", requestHost: "amazon.de.evil.com"))
        #expect(HostMatching.matches(uriHost: "tum.de", requestHost: "login.campus.tum.de"))
    }

    @Test func ipAddressesOnlyMatchExactly() {
        #expect(HostMatching.matches(uriHost: "192.168.1.1", requestHost: "192.168.1.1"))
        #expect(!HostMatching.matches(uriHost: "168.1.1", requestHost: "192.168.1.1"))
        #expect(HostMatching.matches(uriHost: "[fe80::1]", requestHost: "fe80::1"))
    }

    @Test func hostsOfStoredURIs() {
        #expect(HostMatching.host(ofURI: "https://www.amazon.de/ap/signin?x=1") == "www.amazon.de")
        #expect(HostMatching.host(ofURI: "amazon.de") == "amazon.de")
        #expect(HostMatching.host(ofURI: "amazon.de:8443/login") == "amazon.de")
        #expect(HostMatching.host(ofURI: "http://User@Example.COM") == "example.com")
        #expect(HostMatching.host(ofURI: "androidapp://com.amazon.mShop") == nil)
        #expect(HostMatching.host(ofURI: "  ") == nil)
    }

    @Test func loginsWithSeveralURIs() {
        let uris = ["androidapp://de.tum.app", "https://campus.tum.de/tumonline", "moodle.tum.de"]
        #expect(HostMatching.matches(uris: uris, requestHost: "campus.tum.de"))
        #expect(HostMatching.matches(uris: uris, requestHost: "www.moodle.tum.de"))
        #expect(!HostMatching.matches(uris: uris, requestHost: "login.tum.de"))
        #expect(!HostMatching.matches(uris: [], requestHost: "tum.de"))
    }
}
