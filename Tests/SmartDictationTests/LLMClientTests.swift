import XCTest
@testable import SmartDictationLib

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else { return }
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

// MARK: - Helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://localhost:8080/v1/chat/completions")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

// MARK: - Tests

final class LLMClientTests: XCTestCase {

    var client: LLMClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        client = LLMClient(session: makeMockSession())
    }

    // MARK: - 1. Success

    func testSuccessReturnsCorrectText() async throws {
        let responseJSON = """
        {
            "choices": [
                { "message": { "content": "fixed text" } }
            ]
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(statusCode: 200), responseJSON)
        }

        let result = try await client.correct(rawTranscript: "raw text")
        XCTAssertEqual(result, "fixed text")
    }

    // MARK: - 2. Offline

    func testOfflineThrowsLLMErrorOffline() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await client.correct(rawTranscript: "test")
            XCTFail("Expected LLMError.offline to be thrown")
        } catch LLMError.offline {
            // expected
        } catch {
            XCTFail("Expected LLMError.offline, got \(error)")
        }
    }

    // MARK: - 3. Timeout

    func testTimeoutThrowsLLMErrorTimeout() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await client.correct(rawTranscript: "test")
            XCTFail("Expected LLMError.timeout to be thrown")
        } catch LLMError.timeout {
            // expected
        } catch {
            XCTFail("Expected LLMError.timeout, got \(error)")
        }
    }

    // MARK: - 4. Bad HTTP status

    func testBadStatusThrowsLLMErrorBadResponse() async {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(statusCode: 500), Data())
        }

        do {
            _ = try await client.correct(rawTranscript: "test")
            XCTFail("Expected LLMError.badResponse to be thrown")
        } catch LLMError.badResponse(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected LLMError.badResponse(500), got \(error)")
        }
    }

    // MARK: - 5. Bad JSON

    func testBadJSONThrowsLLMErrorDecodingFailed() async {
        let badJSON = "not valid json".data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(statusCode: 200), badJSON)
        }

        do {
            _ = try await client.correct(rawTranscript: "test")
            XCTFail("Expected LLMError.decodingFailed to be thrown")
        } catch LLMError.decodingFailed {
            // expected
        } catch {
            XCTFail("Expected LLMError.decodingFailed, got \(error)")
        }
    }
}
