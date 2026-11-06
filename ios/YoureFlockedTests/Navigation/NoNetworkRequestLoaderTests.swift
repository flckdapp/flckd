import XCTest
@testable import YoureFlocked

/// Guards the claim PRIVACY.md makes: guidance has no network path. If this
/// ever passes data back instead of throwing, the claim is false.
final class NoNetworkRequestLoaderTests: XCTestCase {

    func testEveryRequestThrowsNetworkDisabled() async {
        let loader = NoNetworkRequestLoader()
        let request = URLRequest(url: URL(string: "https://example.invalid/route")!)

        do {
            _ = try await loader.loadData(with: request)
            XCTFail("the guidance loader must never complete a request")
        } catch {
            XCTAssertEqual(error as? NavigationError, .networkDisabled)
        }
    }
}
