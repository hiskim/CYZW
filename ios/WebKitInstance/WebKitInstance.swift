import Foundation
import UIKit
import WebKit

@MainActor
final class WebKitInstance: NSObject, EngineHost {
    let id: UUID
    private(set) var state: EngineState = .idle
    let events: AsyncStream<EngineEvent>

    private var policy: WebKitSandboxPolicy
    private var webView: WKWebView?
    private var userContentController: WKUserContentController?
    private var bridgeMessageHandler: BridgeMessageHandler?
    private var initialURL: URL?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var hasReceivedReady = false
    private var snapshotImages: [UUID: UIImage] = [:]
    private var hasClosed = false
    private let eventContinuation: AsyncStream<EngineEvent>.Continuation

    init(id: UUID = UUID(), sandboxPolicy: WebKitSandboxPolicy = .default) {
        self.id = id
        policy = sandboxPolicy

        var continuation: AsyncStream<EngineEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        super.init()
    }

    func enableStorageForInstance() {
        guard state == .idle else { return }
        policy.allowsStorage = true
    }

    func start(config: EngineConfig) async throws {
        guard !hasClosed else { throw EngineHostError.hostClosed }
        guard case .idle = state else {
            throw emitFailure(.invalidState(expected: "idle", actual: state))
        }
        guard case let .url(url) = config.initialTarget else {
            throw emitFailure(.invalidConfiguration("WebKitInstance requires EngineInitialTarget.url."))
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw emitFailure(.invalidConfiguration("WebKitInstance requires an HTTP(S) URL."))
        }

        state = .starting
        hasReceivedReady = false
        initialURL = url
        configureWebView()
        webView?.load(URLRequest(url: url))

        do {
            try await waitForReady()
            guard !hasClosed else { throw EngineHostError.hostClosed }
            state = .running
            for resource in config.resources {
                try await inject(resource: resource)
            }
        } catch let error as EngineHostError {
            throw emitFailure(error)
        } catch {
            throw emitFailure(.operationFailed(error.localizedDescription))
        }
    }

    func pause() async {
        guard state == .running else { return }
        await runJavaScript("window.dispatchEvent(new Event('engineHostPause'))")
        state = .paused
        eventContinuation.yield(.paused)
    }

    func resume() async {
        guard state == .paused else { return }
        await runJavaScript("window.dispatchEvent(new Event('engineHostResume'))")
        state = .running
        eventContinuation.yield(.resumed)
    }

    func snapshot() async throws -> Snapshot {
        let previousState = state
        guard previousState == .running || previousState == .paused else {
            throw emitFailure(.snapshotUnavailable)
        }
        guard let webView else {
            throw emitFailure(.snapshotUnavailable)
        }

        state = .snapshotting
        do {
            let image = try await takeSnapshot(of: webView)
            let imageID = UUID()
            snapshotImages[imageID] = image
            let scrollPosition = await currentScrollPosition()
            let snapshot = Snapshot(
                engineID: id,
                capturedAt: Date(),
                renderState: previousState == .paused ? .paused : .running,
                camera: .init(x: 0, y: 0, z: 0, zoom: Double(webView.scrollView.zoomScale)),
                scrollPosition: scrollPosition,
                metadata: [
                    "source": "webkit",
                    "imageID": imageID.uuidString,
                    "imageFormat": "UIImage",
                    "imageWidth": String(Int(image.size.width * image.scale)),
                    "imageHeight": String(Int(image.size.height * image.scale))
                ]
            )
            state = previousState
            eventContinuation.yield(.snapshotTaken(snapshot))
            return snapshot
        } catch let error as EngineHostError {
            state = previousState
            throw emitFailure(error)
        } catch {
            state = previousState
            throw emitFailure(.operationFailed(error.localizedDescription))
        }
    }

    func image(for snapshot: Snapshot) -> UIImage? {
        guard let identifier = snapshot.metadata["imageID"], let id = UUID(uuidString: identifier) else {
            return nil
        }
        return snapshotImages[id]
    }

    func inject(resource: ResourceRef) async throws {
        guard !hasClosed else { throw EngineHostError.hostClosed }
        guard state == .running || state == .paused else {
            throw emitFailure(.invalidState(expected: "running or paused", actual: state))
        }

        do {
            let (data, sourceURL) = try await resourceData(for: resource)
            guard let extensionName = sourceURL.pathExtension.lowercased().split(separator: "?").first else {
                throw EngineHostError.resourceUnavailable(resource)
            }
            switch extensionName {
            case "js", "mjs":
                guard let script = String(data: data, encoding: .utf8) else {
                    throw EngineHostError.resourceUnavailable(resource)
                }
                _ = try await evaluateJavaScript(script)
            case "css":
                guard let stylesheet = String(data: data, encoding: .utf8) else {
                    throw EngineHostError.resourceUnavailable(resource)
                }
                _ = try await evaluateJavaScript(styleInjectionScript(stylesheet))
            case "png", "jpg", "jpeg", "webp", "gif", "svg":
                let mimeType = mimeType(for: String(extensionName))
                let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
                _ = try await evaluateJavaScript(imageInjectionScript(dataURL))
            default:
                throw EngineHostError.resourceUnavailable(resource)
            }
            eventContinuation.yield(.resourceInjected(resource))
        } catch let error as EngineHostError {
            throw emitFailure(error)
        } catch {
            throw emitFailure(.operationFailed(error.localizedDescription))
        }
    }

    func close() async {
        guard !hasClosed else { return }
        hasClosed = true
        state = .closing
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        readyContinuation?.resume(throwing: EngineHostError.hostClosed)
        readyContinuation = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        userContentController?.removeScriptMessageHandler(forName: "engineHost")
        userContentController?.removeAllUserScripts()
        bridgeMessageHandler?.delegate = nil
        bridgeMessageHandler = nil
        userContentController = nil
        webView = nil
        snapshotImages.removeAll()

        eventContinuation.yield(.closed)
        eventContinuation.finish()
    }

    private func configureWebView() {
        let contentController = WKUserContentController()
        let bridge = BridgeMessageHandler(delegate: self)
        if policy.allowedPostMessageTargets.contains("engineHost") {
            contentController.add(bridge, name: "engineHost")
        }
        contentController.addUserScript(
            WKUserScript(
                source: sandboxScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: styleInjectionScript(Self.designTokensCSS),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        userContentController = contentController
        bridgeMessageHandler = bridge
    }

    private func waitForReady() async throws {
        if hasReceivedReady { return }
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            if hasReceivedReady {
                resumeReady(with: .success(()))
                return
            }
            readyTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.readyContinuation != nil else { return }
                self.resumeReady(with: .failure(.operationFailed("Timed out waiting for the H5 ready event.")))
            }
        }
    }

    private func resumeReady(with result: Result<Void, EngineHostError>) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    private func takeSnapshot(of webView: WKWebView) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? EngineHostError.snapshotUnavailable)
                }
            }
        }
    }

    private func currentScrollPosition() async -> Snapshot.ScrollPosition {
        guard let value = try? await evaluateJavaScript(
            "({horizontal: window.scrollX || 0, vertical: window.scrollY || 0})"
        ), let position = value as? [String: Any] else {
            return .init(horizontal: 0, vertical: 0)
        }
        return .init(
            horizontal: (position["horizontal"] as? NSNumber)?.doubleValue ?? 0,
            vertical: (position["vertical"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private func evaluateJavaScript(_ source: String) async throws -> Any? {
        guard let webView else { throw EngineHostError.hostClosed }
        return try await webView.evaluateJavaScript(source)
    }

    private func runJavaScript(_ source: String) async {
        _ = try? await evaluateJavaScript(source)
    }

    private func resourceData(for resource: ResourceRef) async throws -> (Data, URL) {
        let url: URL
        switch resource {
        case .local(let path):
            url = URL(fileURLWithPath: path)
        case .remote(let remoteURL):
            guard policy.allowsNavigation(to: remoteURL, initialURL: initialURL) else {
                throw EngineHostError.resourceUnavailable(resource)
            }
            url = remoteURL
        case .bundled(let assetName):
            let nsName = assetName as NSString
            guard let bundledURL = Bundle.main.url(
                forResource: nsName.deletingPathExtension,
                withExtension: nsName.pathExtension.isEmpty ? nil : nsName.pathExtension
            ) else {
                throw EngineHostError.resourceUnavailable(resource)
            }
            url = bundledURL
        }

        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EngineHostError.resourceUnavailable(resource)
            }
            return (try Data(contentsOf: url), url)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw EngineHostError.resourceUnavailable(resource)
        }
        return (data, url)
    }

    private func bridgeError(_ payload: [String: Any]) -> EngineHostError {
        let message = payload["message"] as? String ?? "The H5 page reported an unknown error."
        return .operationFailed(message)
    }

    private func emitFailure(_ error: EngineHostError) -> EngineHostError {
        state = .failed(error)
        eventContinuation.yield(.errorOccurred(error))
        return error
    }

    private func sandboxScript() -> String {
        let allowsCrossOriginFetch = policy.allowsCrossOriginFetch ? "true" : "false"
        let allowsStorage = policy.allowsStorage ? "true" : "false"
        let allowsCookies = policy.allowsCookies ? "true" : "false"
        return """
        (() => {
          const allowsCrossOriginFetch = \(allowsCrossOriginFetch);
          const allowsStorage = \(allowsStorage);
          const allowsCookies = \(allowsCookies);
          const assertSameOrigin = (input) => {
            const candidate = typeof input === 'string' ? input : input.url;
            const target = new URL(candidate, window.location.href);
            if (!allowsCrossOriginFetch && target.origin !== window.location.origin) {
              throw new DOMException('Cross-origin fetch is disabled for this instance.', 'SecurityError');
            }
          };
          const nativeFetch = window.fetch.bind(window);
          window.fetch = (input, init) => {
            try { assertSameOrigin(input); } catch (error) { return Promise.reject(error); }
            return nativeFetch(input, init);
          };
          const nativeOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            assertSameOrigin(url);
            return nativeOpen.call(this, method, url, ...rest);
          };
          if (!allowsStorage) {
            for (const key of ['localStorage', 'sessionStorage']) {
              try { Object.defineProperty(window, key, { get: () => { throw new DOMException('Storage is disabled for this instance.', 'SecurityError'); } }); } catch (_) {}
            }
          }
          if (!allowsCookies) {
            try { Object.defineProperty(Document.prototype, 'cookie', { get: () => '', set: () => undefined }); } catch (_) {}
          }
        })();
        """
    }

    private func styleInjectionScript(_ stylesheet: String) -> String {
        let encoded = Data(stylesheet.utf8).base64EncodedString()
        return """
        (() => {
          const style = document.createElement('style');
          style.dataset.engineHost = 'design-tokens';
          style.textContent = atob('\(encoded)');
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    private func imageInjectionScript(_ source: String) -> String {
        let encoded = Data(source.utf8).base64EncodedString()
        return """
        (() => {
          const image = new Image();
          image.dataset.engineHostResource = 'image';
          image.src = atob('\(encoded)');
          image.style.display = 'none';
          document.body.appendChild(image);
          window.dispatchEvent(new CustomEvent('engineHostResource', { detail: { type: 'image', source: image.src } }));
        })();
        """
    }

    private func mimeType(for extensionName: String) -> String {
        switch extensionName {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        default: return "image/png"
        }
    }

    private static var designTokensCSS: String {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "design-tokens", withExtension: "css", subdirectory: "shared")
            ?? bundle.url(forResource: "design-tokens", withExtension: "css")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

extension WebKitInstance: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(policy.allowsNavigation(to: url, initialURL: initialURL) ? .allow : .cancel)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.resumeReady(with: .failure(.operationFailed(error.localizedDescription)))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.resumeReady(with: .failure(.operationFailed(error.localizedDescription)))
        }
    }
}

extension WebKitInstance: BridgeMessageHandling {
    func bridgeDidReceive(event: String, payload: [String: Any]) {
        switch event {
        case "ready":
            hasReceivedReady = true
            resumeReady(with: .success(()))
            eventContinuation.yield(.ready)
        case "paused":
            state = .paused
            eventContinuation.yield(.paused)
        case "resumed":
            state = .running
            eventContinuation.yield(.resumed)
        case "error":
            let error = bridgeError(payload)
            _ = emitFailure(error)
        default:
            let serializablePayload = payload.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
            eventContinuation.yield(.bridgeMessage(name: event, payload: serializablePayload))
        }
    }
}
