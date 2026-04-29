import Foundation
import XCTest
@testable import Orbit

@MainActor
final class ProviderBridgeDebugStoreTests: XCTestCase {
    func testRingBuffersAndClear() {
        let store = ProviderBridgeDebugStore(requestLimit: 2, eventLimit: 3)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()

        store.recordRequestStarted(
            id: firstID,
            bridgeBaseURL: "http://127.0.0.1:1",
            upstreamBaseURL: "https://api.one.test/v1",
            path: "/responses",
            model: "one",
            stream: false,
            hasMedia: false,
            multimodalModel: nil,
            payloadPreview: "first"
        )
        store.recordRequestStarted(
            id: secondID,
            bridgeBaseURL: "http://127.0.0.1:2",
            upstreamBaseURL: "https://api.two.test/v1",
            path: "/responses",
            model: "two",
            stream: true,
            hasMedia: true,
            multimodalModel: "two-vision",
            payloadPreview: "second"
        )
        store.recordRequestStarted(
            id: thirdID,
            bridgeBaseURL: "http://127.0.0.1:3",
            upstreamBaseURL: "https://api.three.test/v1",
            path: "/responses",
            model: "three",
            stream: false,
            hasMedia: true,
            multimodalModel: "three-vision",
            payloadPreview: "third"
        )

        XCTAssertEqual(store.requests.map(\.id), [secondID, thirdID])
        XCTAssertEqual(store.activeRequestCount, 2)
        XCTAssertEqual(store.latestBridgeBaseURL, "http://127.0.0.1:3")
        XCTAssertEqual(store.latestUpstreamBaseURL, "https://api.three.test/v1")
        XCTAssertEqual(store.events.count, 3)

        store.appendEvent(requestID: thirdID, title: "extra", detail: "detail", payloadPreview: "payload")
        XCTAssertEqual(store.events.count, 3)

        store.recordRequestFinished(id: secondID, status: .completed, httpStatus: 200, errorMessage: nil)
        XCTAssertEqual(store.activeRequestCount, 1)

        store.clear()
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
    }
}
