import XCTest
import UIKit
@testable import GameShell

@MainActor
final class CocosNativeInstanceTests: XCTestCase {
    func testOnlyOneCocosInstanceCanExistAtATime() async throws {
        let first = try CocosNativeInstance(runtime: TestCocosRuntime())

        XCTAssertThrowsError(try CocosNativeInstance(runtime: TestCocosRuntime())) { error in
            XCTAssertEqual(error as? EngineHostError, .notMultiInstanceSupported)
        }

        await first.close()
        let replacement = try CocosNativeInstance(runtime: TestCocosRuntime())
        await replacement.close()
    }
}

@MainActor
private final class TestCocosRuntime: CocosRuntimeAdapting {
    let ccView = UIView()

    func loadSceneBundle(identifier: String) throws {}
    func startDirector(sceneName: String, authenticationToken: String) throws {}
    func pauseDirector() {}
    func resumeDirector() {}
    func captureFrame(completion: @escaping (UIImage?, Error?) -> Void) { completion(UIImage(), nil) }
    func evaluateJSB(_ script: String) throws {}
    func endDirector() {}
}
