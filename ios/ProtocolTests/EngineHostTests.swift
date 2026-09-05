import XCTest
@testable import GameShell

@MainActor
final class EngineHostTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EngineHostRegistry.shared.removeAll()
    }

    func testDefaultStateAndProtocolActivity() {
        let host: EngineHost = MockEngineHost()

        XCTAssertEqual(host.state, .idle)
        XCTAssertFalse(host.isActive)
        XCTAssertTrue(EngineConfig.preview.resources.isEmpty)
    }

    func testStartFailurePropagatesThroughThrowAndEventStream() async {
        let host = MockEngineHost()
        let expectedError = EngineHostError.operationFailed("Injected start failure")
        host.nextStartError = expectedError
        var iterator = host.events.makeAsyncIterator()

        do {
            try await host.start(config: .preview)
            XCTFail("Expected start to throw")
        } catch let error as EngineHostError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(host.state, .failed(expectedError))
        let event = await iterator.next()
        XCTAssertEqual(event, .errorOccurred(expectedError))
    }

    func testRegistryFindsRegisteredHostByID() {
        let host = MockEngineHost()

        EngineHostRegistry.shared.register(host)

        XCTAssertTrue(EngineHostRegistry.shared.host(for: host.id) === host)
        EngineHostRegistry.shared.unregister(id: host.id)
        XCTAssertNil(EngineHostRegistry.shared.host(for: host.id))
    }
}
