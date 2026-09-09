#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import WebKit

/// SwiftUI bridge used by the macOS multi-open matrix. Each representable
/// creates a fresh `MacWebKitGameView`, and therefore a fresh non-persistent
/// website data store and isolated game session.
struct MacEmbeddedGameView: NSViewRepresentable {
    let account: Account

    func makeNSView(context: Context) -> MacWebKitGameView {
        let view = MacWebKitGameView(account: account)
        view.start()
        return view
    }

    func updateNSView(_ nsView: MacWebKitGameView, context: Context) {}
}

@MainActor
enum MacWebKitGameWindowController {
    private static var windows: [UUID: NSWindowController] = [:]

    static func open(account: Account) {
        let identifier = UUID()
        let gameView = MacWebKitGameView(account: account)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = account.nickname + " - WebKit"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.contentView = gameView
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windows[identifier] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                windows.removeValue(forKey: identifier)
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        gameView.start()
    }
}

final class MacWebKitGameView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private let account: Account
    private let instanceID = UUID().uuidString
    private var authenticatedAccountID = ""
    private let schemeHandler = MacGameSchemeHandler()
    private lazy var webView: WKWebView = makeWebView()
    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在准备游戏资源…")
    private var gameSessionStarted = false

    init(account: Account) {
        self.account = account
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(webView)

        // Do not leave an empty white WebKit surface visible while the shared
        // CDN warm-up and account authentication are in flight.
        loadingOverlay.wantsLayer = true
        loadingOverlay.layer?.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.075, blue: 0.094, alpha: 1).cgColor
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingOverlay)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isIndeterminate = true
        loadingSpinner.startAnimation(nil)
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingSpinner)

        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.font = .systemFont(ofSize: 14)
        loadingLabel.alignment = .center
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingLabel)

        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -14),
            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 12),
            loadingLabel.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if gameSessionStarted {
            Task { await MacCDNResourceManager.shared.endGameSession() }
        }
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // App launch starts the shared CDN prefetch. Awaiting the same
                // actor task here means an early account click does not create
                // a second download or race the cache warm-up.
                let manifest = await MacCDNResourceManager.shared.prepareForLaunch()
                loadingLabel.stringValue = "正在登录游戏…"
                NSLog("[ios2-macos] account authentication started: %@", account.fileName)
                let authentication = try await MacWebKitAuth.authenticate(account: account, manifest: manifest)
                NSLog("[ios2-macos] account authentication complete: %@", account.fileName)
                await MacCDNResourceManager.shared.beginGameSession()
                gameSessionStarted = true
                authenticatedAccountID = authentication.accountID
                schemeHandler.setBundleVersions(authentication.bundleVersions)
                webView.configuration.userContentController.addUserScript(
                    WKUserScript(source: bootstrapScript(authResponse: authentication.authResponse,
                                                         manifestJSON: authentication.manifestJSON),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true)
                )
                let entry = URL(string: "ios2-game://app/index.html?revision=macos-webkit-2")!
                NSLog("[ios2-macos] loading WebKit game document: %@", entry.absoluteString)
                webView.load(URLRequest(url: entry))
            } catch {
                loadingSpinner.stopAnimation(nil)
                loadingLabel.stringValue = "登录失败：\(error.localizedDescription)"
                showError(title: "账号登录失败", message: error.localizedDescription)
            }
        }
    }

    private func makeWebView() -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(self, name: "ios2Game")

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "ios2-game")
        // A separate non-persistent store prevents account cookies and web
        // storage from bleeding between independently opened game windows.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let result = WKWebView(frame: .zero, configuration: configuration)
        result.navigationDelegate = self
        result.allowsBackForwardNavigationGestures = false
        return result
    }

    private func bootstrapScript(authResponse: String, manifestJSON: String) -> String {
        let accountJSON = try? String(data: JSONEncoder().encode(account.nickname), encoding: .utf8)
        let idJSON = try? String(data: JSONEncoder().encode(instanceID), encoding: .utf8)
        let authJSON = try? String(data: JSONEncoder().encode(authResponse), encoding: .utf8)
        let manifestValue: String
        if let data = manifestJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let encoded = try? JSONSerialization.data(withJSONObject: object),
           let value = String(data: encoded, encoding: .utf8) {
            manifestValue = value
        } else {
            manifestValue = "{}"
        }
        return """
        window.__IOS2_GAME_INSTANCE__ = {
          id: \(idJSON ?? "\\\"\\\""),
          account: \(accountJSON ?? "\\\"账号\\\""),
          authResponse: \(authJSON ?? "\\\"\\\"") ,
          frameRate: 60,
          qualitySingle: 'high',
          qualityMulti: 'medium',
          multiOpen: false,
          startupMode: 'serial',
          scripts: [],
          manifest: \(manifestValue),
        };
        window.jsb = window.jsb || {};
        window.jsb.reflection = window.jsb.reflection || {};
        window.jsb.reflection.callStaticMethod = function() {
          var args = Array.prototype.slice.call(arguments), klass = args.shift(), method = args.shift();
          if (klass === 'IOS2Native' && method === 'runtimeBackend') return 'webkit';
          // HSDK selects the iOS class only when cc.sys reports iOS. A
          // macOS WebKit page reports macOS, so the same SDK build otherwise
          // falls back to its Android-style class/method pair and the request
          // silently disappears. Accept both native entry points here; the
          // payload format is identical.
          if ((klass === 'SDKMessager' && method === 'callNative:withMessage:') ||
              (klass === 'com/hortorgames/gamesdk/SDKBridge' && method === 'receiveMsgFromHSDK')) {
            var hsdkChannel = method === 'receiveMsgFromHSDK' ? 'sdk' : (args[0] || 'sdk');
            var hsdkMessage = method === 'receiveMsgFromHSDK' ? args[1] : args[1];
            try { window.webkit.messageHandlers.ios2Game.postMessage({type:'hsdk', instance: window.__IOS2_GAME_INSTANCE__.id, channel: hsdkChannel, message: String(hsdkMessage || '{}')}); } catch (error) { console.error(error); }
          }
          return null;
        };
        var __ios2AuthBuffer = null;
        function __ios2AuthBytes() {
          if (__ios2AuthBuffer) return __ios2AuthBuffer.slice(0);
          var binary = atob(window.__IOS2_GAME_INSTANCE__.authResponse || ''), bytes = new Uint8Array(binary.length);
          for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          __ios2AuthBuffer = bytes.buffer;
          window.__IOS2_GAME_INSTANCE__.authResponse = '';
          return __ios2AuthBuffer.slice(0);
        }
        console.log('[ios2-macos] live manifest injected',
          window.__IOS2_GAME_INSTANCE__.manifest &&
          window.__IOS2_GAME_INSTANCE__.manifest.bundleVers);
        var __ios2NativeXHR = window.XMLHttpRequest;
        function __ios2XHR() {
          this._native = new __ios2NativeXHR(); this._fake = false; this._readyState = 0; this._status = 0;
          this._response = null; this._responseType = ''; this._listeners = {};
          var self = this;
          ['readystatechange','load','error','timeout','abort','loadend','progress'].forEach(function(type) {
            self._native['on' + type] = function(event) { self._emit(type, event); };
          });
        }
        __ios2XHR.prototype.open = function(method, url) {
          this._fake = /\\/login\\/authuser(?:\\?|$)/.test(String(url || ''));
          if (this._fake) { this._readyState = 1; this._emit('readystatechange'); }
          else this._native.open.apply(this._native, arguments);
        };
        __ios2XHR.prototype.send = function(body) {
          if (!this._fake) return this._native.send(body);
          var self = this; setTimeout(function() {
            self._status = 200; self._response = __ios2AuthBytes();
            self._readyState = 2; self._emit('readystatechange');
            self._readyState = 3; self._emit('readystatechange');
            self._readyState = 4; self._emit('readystatechange'); self._emit('load'); self._emit('loadend');
          }, 0);
        };
        __ios2XHR.prototype.abort = function() { if (this._fake) { this._readyState = 0; this._emit('abort'); this._emit('loadend'); } else this._native.abort(); };
        __ios2XHR.prototype.setRequestHeader = function(name, value) { if (!this._fake) this._native.setRequestHeader(name, value); };
        __ios2XHR.prototype.getAllResponseHeaders = function() { return this._fake ? 'Content-Type: application/octet-stream\\r\\n' : this._native.getAllResponseHeaders(); };
        __ios2XHR.prototype.getResponseHeader = function(name) { return this._fake && String(name).toLowerCase() === 'content-type' ? 'application/octet-stream' : (this._fake ? null : this._native.getResponseHeader(name)); };
        __ios2XHR.prototype.overrideMimeType = function(value) { if (!this._fake && this._native.overrideMimeType) this._native.overrideMimeType(value); };
        __ios2XHR.prototype.addEventListener = function(type, listener) { if (typeof listener === 'function') (this._listeners[type] || (this._listeners[type] = [])).push(listener); };
        __ios2XHR.prototype.removeEventListener = function(type, listener) { var list = this._listeners[type] || [], index = list.indexOf(listener); if (index >= 0) list.splice(index, 1); };
        __ios2XHR.prototype._emit = function(type, event) { event = event || {type:type, target:this}; var handler = this['on' + type]; if (typeof handler === 'function') handler.call(this, event); var list = (this._listeners[type] || []).slice(); for (var i = 0; i < list.length; i++) list[i].call(this, event); };
        Object.defineProperties(__ios2XHR.prototype, {
          readyState:{get:function(){return this._fake ? this._readyState : this._native.readyState;}},
          status:{get:function(){return this._fake ? this._status : this._native.status;}},
          statusText:{get:function(){return this._fake ? 'OK' : this._native.statusText;}},
          response:{get:function(){return this._fake ? this._response : this._native.response;}},
          responseText:{get:function(){return this._fake ? '' : this._native.responseText;}},
          responseType:{get:function(){return this._fake ? this._responseType : this._native.responseType;},set:function(value){this._responseType=value||'';if(!this._fake)this._native.responseType=value;}},
          timeout:{get:function(){return this._native.timeout;},set:function(value){this._native.timeout=value;}},
          withCredentials:{get:function(){return this._fake ? false : this._native.withCredentials;},set:function(value){if(!this._fake)this._native.withCredentials=value;}}
        });
        __ios2XHR.UNSENT = 0; __ios2XHR.OPENED = 1; __ios2XHR.HEADERS_RECEIVED = 2; __ios2XHR.LOADING = 3; __ios2XHR.DONE = 4;
        window.XMLHttpRequest = __ios2XHR;
        window.addEventListener('error', function(event) {
          try { window.webkit.messageHandlers.ios2Game.postMessage({type:'error', instance:window.__IOS2_GAME_INSTANCE__.id, message:String(event.error && event.error.stack || event.message || 'Web game error')}); } catch (ignored) {}
        });
        window.addEventListener('unhandledrejection', function(event) {
          try { window.webkit.messageHandlers.ios2Game.postMessage({type:'error', instance:window.__IOS2_GAME_INSTANCE__.id, message:String(event.reason && event.reason.stack || event.reason || 'Unhandled rejection')}); } catch (ignored) {}
        });
        ['log','warn','error'].forEach(function(level) {
          var original = console[level];
          console[level] = function() {
            var args = Array.prototype.slice.call(arguments);
            try { window.webkit.messageHandlers.ios2Game.postMessage({type:'console', level:level, instance:window.__IOS2_GAME_INSTANCE__.id, message:args.map(function(value){ return String(value && value.stack || value); }).join(' ')}); } catch (ignored) {}
            return original.apply(console, args);
          };
        });
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ios2Game" else { return }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            NSLog("[ios2-macos] WebKit event: %@", String(describing: message.body))
            return
        }
        switch type {
        case "hsdk":
            guard let requestJSON = body["message"] as? String else {
                NSLog("[ios2-macos] malformed HSDK event: %@", String(describing: body))
                return
            }
            handleHSDKRequest(requestJSON)
        case "console":
            NSLog("[ios2-macos] JS %@: %@", body["level"] as? String ?? "log", body["message"] as? String ?? "")
        case "error":
            NSLog("[ios2-macos] JS error: %@", body["message"] as? String ?? "Unknown error")
        default:
            NSLog("[ios2-macos] WebKit event: %@", String(describing: body))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingOverlay.isHidden = true
        NSLog("[ios2-macos] WebKit game document loaded")
    }

    private func showNavigationError(_ error: Error) {
        loadingSpinner.stopAnimation(nil)
        loadingLabel.stringValue = "游戏页面加载失败：\(error.localizedDescription)"
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window ?? NSApp.mainWindow ?? NSWindow())
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window ?? NSApp.mainWindow ?? NSWindow())
    }

    private func handleHSDKRequest(_ requestJSON: String) {
        guard let data = requestJSON.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = request["action"] as? String else { return }
        let extra = request["extra"] as? [String: Any] ?? [:]
        NSLog("[ios2-macos] HSDK request: %@", action)
        let responseExtra: [String: Any]
        switch action {
        case "game-init":
            responseExtra = ["gameID": "xyzw_mix", "env": 0, "gameVersion": "0.33.0-ios",
                             "channel": "AppStore", "distinctId": accountID(),
                             "deviceInfo": deviceInfo()]
        case "user_login_show_dialog", "user-tokenlogin", "user-multi-platform-login":
            // The selected .bin was authenticated before this WebKit instance
            // was created. Match iOS loginForSDK: publish the listener event
            // first, then resolve the SDK login promise.
            sendHSDKMessage(action: "sdk-get-userId",
                            extra: ["userId": accountID(), "uniqueId": accountID()],
                            errorCode: 0)
            sendHSDKMessage(action: action, extra: [:], errorCode: 0)
            return
        case "user-logout":
            sendHSDKMessage(action: action, extra: [:], errorCode: 0)
            sendHSDKMessage(action: "user-logout-from-sdk", extra: [:], errorCode: 0)
            return
        case "sdk-get-device-info":
            responseExtra = ["deviceUniqueId": accountID(), "gameId": "xyzw_mix", "gameTp": "ios",
                             "uniqueId": accountID(), "sysInfo": deviceInfo()]
        case "sdk-get-userId", "user-getuserinfo":
            responseExtra = ["userId": accountID(), "uniqueId": accountID()]
        case "get-check-switchs":
            let switchIDs = extra["switchIdList"] as? [Any] ?? []
            let values = switchIDs.map { value -> Int in
                guard let switchID = value as? String else { return 0 }
                return ["ChatWorldSwitch", "PaySwitch", "FasterSubPage", "ControllerSubPage"].contains(switchID) ? 1 : 0
            }
            responseExtra = ["sequence": extra["sequence"] as? NSNumber ?? 0,
                             "data": values]
        case "sdk-sync-passbord":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((extra["text"] as? String) ?? (extra["data"] as? String) ?? "", forType: .string)
            responseExtra = [:]
        case "sdk-get-passbord":
            responseExtra = ["text": NSPasteboard.general.string(forType: .string) ?? ""]
        case "game_addiction_quit", "send-url-param", "app-activity-resume", "app-activity-pause",
             "sdk-app-back":
            // These are event/listener registrations on iOS. Replying here
            // would invoke the listener during startup as if the event fired.
            NSLog("[ios2-macos] HSDK listener registered: %@", action)
            return
        default:
            responseExtra = [:]
        }
        sendHSDKMessage(action: action, extra: responseExtra, errorCode: 0)
    }

    private func deviceInfo() -> [String: String] {
        ["deviceSystem": "macOS", "deviceModel": "Mac", "deviceBrand": "Apple",
         "deviceVersion": ProcessInfo.processInfo.operatingSystemVersionString,
         "hortorSDKVersion": "1.4.0", "deviceName": Host.current().localizedName ?? "Mac"]
    }

    private func sendHSDKMessage(action: String, extra: [String: Any], errorCode: Int) {
        let payload: [String: Any] = ["action": action, "meta": ["errCode": errorCode], "extra": extra]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: data, encoding: .utf8),
              // JSONSerialization rejects a top-level Swift String on newer
              // Foundation implementations (and throws an Obj-C exception
              // that Swift try? cannot catch). JSONEncoder safely produces
              // the quoted JS string literal needed by HSDK.onMessage.
              let messageData = try? JSONEncoder().encode(message),
              let argument = String(data: messageData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("if(window.HSDK&&typeof window.HSDK.onMessage==='function'){window.HSDK.onMessage('sdk',\(argument));}else{throw new Error('HSDK.onMessage is unavailable while responding to \(action)');}") { _, error in
            if let error {
                NSLog("[ios2-macos] HSDK response %@ failed: %@", action, error.localizedDescription)
            } else {
                NSLog("[ios2-macos] HSDK response sent: %@", action)
            }
        }
    }

    private func accountID() -> String {
        if !authenticatedAccountID.isEmpty { return authenticatedAccountID }
        let digest = SHA256.hash(data: Data(account.fileName.utf8))
        return "ios2-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum MacWebKitAuth {
    private static let gameServer = "https://xxz-xyzw.hortorgames.com"

    struct Result {
        let authResponse: String
        let accountID: String
        let manifestJSON: String
        let bundleVersions: [String: String]
    }
    enum AuthError: LocalizedError {
        case missingFile
        case invalidResponse(String)
        var errorDescription: String? {
            switch self {
            case .missingFile: return "找不到账号 .bin 文件。"
            case .invalidResponse(let detail): return detail
            }
        }
    }

    static func authenticate(account: Account, manifest: MacCDNManifest? = nil) async throws -> Result {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AuthError.missingFile
        }
        let fileURL = documents.appendingPathComponent("ios2/bins", isDirectory: true)
            .appendingPathComponent(account.fileName)
        guard let binData = try? Data(contentsOf: fileURL), !binData.isEmpty else {
            throw AuthError.missingFile
        }
        var request = URLRequest(url: URL(string: "\(gameServer)/login/authuser?_seq=1")!)
        request.httpMethod = "POST"
        request.httpBody = binData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("lx", forHTTPHeaderField: "O4e-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count > 4 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthError.invalidResponse("认证服务返回异常（HTTP \(status)）。")
        }

        let liveManifest: MacCDNManifest
        if let manifest {
            liveManifest = manifest
        } else {
            liveManifest = try await MacCDNResourceManager.shared.latestManifest()
        }
        let bundleVersions = liveManifest.bundleVersions

        let digest = SHA256.hash(data: binData)
        let accountID = "ios2-" + digest.map { String(format: "%02x", $0) }.joined()
        return Result(authResponse: data.base64EncodedString(), accountID: accountID,
                      manifestJSON: liveManifest.json,
                      bundleVersions: bundleVersions)
    }
}

private final class MacGameSchemeHandler: NSObject, WKURLSchemeHandler {
    private let remoteBaseURL = URL(string: "https://xxz-xyzw-res.hortorgames.com")!
    private var bundleVersions: [String: String] = [:]

    func setBundleVersions(_ versions: [String: String]) {
        bundleVersions = versions
        NSLog("[ios2-macos] live bundle versions: launcher=%@ game=%@ internal=%@",
              versions["launcher"] ?? "<missing>",
              versions["game"] ?? "<missing>",
              versions["internal"] ?? "<missing>")
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: NSURLErrorBadURL)
            return
        }

        if let localURL = localResource(for: requestURL) {
            do {
                try respond(urlSchemeTask, data: Data(contentsOf: localURL), url: requestURL)
            } catch {
                urlSchemeTask.didFailWithError(error)
            }
            return
        }

        guard let remoteURL = remoteResource(for: requestURL) else {
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
            return
        }
        NSLog("[ios2-macos] CDN request: %@ -> %@", requestURL.absoluteString, remoteURL.absoluteString)
        Task { @MainActor [weak self] in
            do {
                let data = try await MacCDNResourceManager.shared.data(for: remoteURL, source: "game")
                self?.respond(urlSchemeTask, data: data, url: requestURL)
            } catch {
                NSLog("[ios2-macos] CDN error: %@ (%@)", remoteURL.absoluteString, error.localizedDescription)
                self?.fail(urlSchemeTask, code: (error as NSError).code)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // The shared actor may still finish a request for another window.
        // WebKit ignores callbacks for a stopped scheme task, so no per-window
        // cancellation or cache bookkeeping is needed here.
    }

    private func localResource(for url: URL) -> URL? {
        guard url.host == "app", let root = Bundle.main.resourceURL?.appendingPathComponent("WebRuntime") else {
            return nil
        }
        let path = url.path
        let aliases = [
            "/index.html": "src/ios2-web-index.html",
            "/settings.js": "src/settings.b2e22.js",
            "/cocos2d.js": "src/ios2-web-cocos2d.js",
            "/physics.js": "src/ios2-web-physics.js",
            "/boot.js": "src/ios2-web-boot.js",
            "/game-defines.js": "jsb-adapter/game-defines.js"
        ]
        let relativePath: String
        if let alias = aliases[path] {
            relativePath = alias
        } else if path.hasPrefix("/src/") || path.hasPrefix("/assets/") || path.hasPrefix("/jsb-adapter/") {
            relativePath = String(path.dropFirst())
        } else {
            return nil
        }

        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    private func remoteResource(for url: URL) -> URL? {
        guard url.host == "app" || url.host == "cdn" else { return nil }
        let path: String
        if url.host == "app" {
            guard !url.path.hasPrefix("/cdn/") else {
                path = String(url.path.dropFirst(4))
                return remoteURL(path: rewriteBundleVersion(in: path), query: url.query)
            }
            path = "/remote" + url.path
        } else {
            path = url.path
        }
        return remoteURL(path: rewriteBundleVersion(in: path), query: url.query)
    }

    private func rewriteBundleVersion(in path: String) -> String {
        guard !bundleVersions.isEmpty else { return path }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3 else { return path }

        for index in components.indices {
            guard let version = bundleVersions[components[index]],
                  components.index(after: index) < components.endIndex else { continue }
            let filenameIndex = components.index(after: index)
            let filename = components[filenameIndex]
            let filenameParts = filename.split(separator: ".", omittingEmptySubsequences: false)
            guard filenameParts.count == 3,
                  filenameParts[0] == "index",
                  filenameParts[2] == "js" || filenameParts[2] == "jsc" else { continue }
            components[filenameIndex] = "index.\(version).\(filenameParts[2])"
            NSLog("[ios2-macos] bundle URL rewritten: %@ -> %@", path, components.joined(separator: "/"))
            return components.joined(separator: "/")
        }
        return path
    }

    private func remoteURL(path: String, query: String?) -> URL? {
        var components = URLComponents(url: remoteBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.query = query
        return components?.url
    }

    private func respond(_ task: WKURLSchemeTask, data: Data, url: URL) {
        // Fetch/XHR only exposes `ok` and `status` when the custom scheme
        // returns an HTTP response. A plain URLResponse makes a successful
        // CDN download look like status 0 to the WebKit runtime.
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType(for: url.pathExtension),
                "Content-Length": String(data.count),
                "Cache-Control": "no-store"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": return "text/html"
        case "js", "mjs", "jsc": return "application/javascript"
        case "json": return "application/json"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}
#endif
