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

#if os(macOS)
    func testGroupedSyncRoutesOnlyInsideSenderGroup() {
        // 控制器会先按发送者的 groupID 取出这一个分组的参与名单，
        // 再调用纯路由函数；因此 B 组成员不会进入本次目标集合。
        let groupAReceivers: Set<String> = ["a1", "a2"]

        let targets = MacInputSyncController.routingTargets(
            master: nil,
            receivers: groupAReceivers,
            sender: "a1"
        )

        XCTAssertEqual(targets, Set(["a2"]))
    }

    func testMasterDrivenRoutingSilencesNonMaster() {
        let receivers: Set<String> = ["a1", "a2", "a3"]

        XCTAssertEqual(
            MacInputSyncController.routingTargets(master: "a1", receivers: receivers, sender: "a1"),
            Set(["a2", "a3"])
        )
        XCTAssertTrue(
            MacInputSyncController.routingTargets(master: "a1", receivers: receivers, sender: "a2").isEmpty
        )
    }

    func testCaptureStateMatchesGroupMode() {
        let receivers: Set<String> = ["a1", "a2"]

        XCTAssertTrue(MacInputSyncController.shouldCapture(master: nil, receivers: receivers, account: "a1"))
        XCTAssertTrue(MacInputSyncController.shouldCapture(master: "a1", receivers: receivers, account: "a1"))
        XCTAssertFalse(MacInputSyncController.shouldCapture(master: "a1", receivers: receivers, account: "a2"))
    }
#endif
}
