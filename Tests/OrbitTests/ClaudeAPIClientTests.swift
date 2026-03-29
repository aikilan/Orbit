import Foundation
import XCTest
@testable import Orbit

final class ClaudeAPIClientTests: XCTestCase {
    func testProbeStatusUsesModelsHeadersWhenAvailable() async throws {
        let recorder = RequestRecorder<URLRequest>()
        ClaudeMockURLProtocol.requestHandler = { request in
            recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "anthropic-ratelimit-requests-limit": "100",
                    "anthropic-ratelimit-requests-remaining": "42",
                    "anthropic-ratelimit-requests-reset": "2026-03-26T12:00:00Z",
                    "Content-Type": "application/json",
                ]
            )!
            return (response, Data(#"{"data":[{"id":"claude-3-5-haiku-latest"}]}"#.utf8))
        }

        let client = ClaudeAPIClient(
            configuration: ClaudeAPIClientConfiguration(baseURL: URL(string: "https://anthropic.test")!),
            session: makeSession()
        )

        let snapshot = try await client.probeStatus(using: AnthropicAPIKeyCredential(apiKey: "sk-ant-test"))
        let requests = recorder.values

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/models")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(snapshot.requests.limit, 100)
        XCTAssertEqual(snapshot.requests.remaining, 42)
        XCTAssertEqual(snapshot.source, .onlineUsageRefresh)
    }

    func testProbeStatusFallsBackToMessagesWhenModelsHeadersMissing() async throws {
        let recorder = RequestRecorder<String>()
        ClaudeMockURLProtocol.requestHandler = { request in
            let path = try XCTUnwrap(request.url?.path)
            recorder.append(path)

            switch path {
            case "/v1/models":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"data":[{"id":"claude-3-5-haiku-latest"}]}"#.utf8))
            case "/v1/messages":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = String(data: try XCTUnwrap(Self.requestBody(from: request)), encoding: .utf8)
                XCTAssertTrue(body?.contains("\"ping\"") == true)
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "anthropic-ratelimit-input-tokens-limit": "1000",
                        "anthropic-ratelimit-input-tokens-remaining": "999",
                        "anthropic-ratelimit-output-tokens-limit": "2000",
                        "anthropic-ratelimit-output-tokens-remaining": "1999",
                        "anthropic-ratelimit-requests-limit": "50",
                        "anthropic-ratelimit-requests-remaining": "49",
                    ]
                )!
                return (response, Data("{}".utf8))
            default:
                XCTFail("Unexpected path: \(path)")
                throw NSError(domain: "test", code: 1)
            }
        }

        let client = ClaudeAPIClient(
            configuration: ClaudeAPIClientConfiguration(baseURL: URL(string: "https://anthropic.test")!),
            session: makeSession()
        )

        let snapshot = try await client.probeStatus(using: AnthropicAPIKeyCredential(apiKey: "sk-ant-test"))
        let requestPaths = recorder.values

        XCTAssertEqual(requestPaths, ["/v1/models", "/v1/messages"])
        XCTAssertEqual(snapshot.requests.remaining, 49)
        XCTAssertEqual(snapshot.inputTokens.remaining, 999)
        XCTAssertEqual(snapshot.outputTokens.remaining, 1999)
    }

    override func tearDown() {
        super.tearDown()
        ClaudeMockURLProtocol.requestHandler = nil
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }

        return data.isEmpty ? nil : data
    }
}

private final class ClaudeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}
