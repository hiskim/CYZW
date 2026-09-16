import AppKit
import WebKit
import UniformTypeIdentifiers

let OUT = "/tmp/dlprobe/result.txt"
var logLines: [String] = []
func note(_ s: String) { logLines.append(s); print(s) }
func dump() { try? logLines.joined(separator: "\n").write(toFile: OUT, atomically: true, encoding: .utf8) }

final class Probe: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var window: NSWindow!
    var downloads: [ObjectIdentifier: Probe] = [:]
    var shimmed = false
    var downloadEntered = false
    var destinationRequested = false
    var savedPath: String?

    func start(shim: Bool) {
        shimmed = shim
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "probe")
        config.userContentController = controller
        if shim {
            // 与 ios2-script-runtime.js 的 _installDownloadBridge 同款逻辑（精简）
            let js = """
            (function(){
              var store = {}, seq = 0;
              var nc = URL.createObjectURL;
              URL.createObjectURL = function(b){ var u = nc.call(URL,b); store[u]=b; return u; };
              window.__probe = function(t){ window.webkit.messageHandlers.probe.postMessage({k:t}); };
              var click = HTMLAnchorElement.prototype.click;
              HTMLAnchorElement.prototype.click = function(){
                try {
                  if (this.hasAttribute('download') || this.download) {
                    var href = this.getAttribute('href') || this.href || '';
                    if (/^blob:/i.test(href) && store[href]) {
                      window.__probe('shim-intercepted:' + this.download);
                      store[href].arrayBuffer().then(function(buf){
                        var bytes = new Uint8Array(buf), s = '';
                        for (var i=0;i<bytes.length;i++) s += String.fromCharCode(bytes[i]);
                        window.webkit.messageHandlers.probe.postMessage({k:'blob-bytes:' + btoa(s)});
                      });
                      return;
                    }
                  }
                } catch(e){ window.__probe('shim-error:' + e); }
                return click.apply(this, arguments);
              };
            })();
            """
            controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        let html = """
        <!doctype html><html><body><canvas id="GameCanvas"></canvas></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://ios2.local/"))
    }

    var kind = "blob"
    func fire() {
        let js: String
        if kind == "data" {
            js = """
            (function(){
              var a = document.createElement('a');
              a.href = 'data:text/plain;base64,REFUQS1QQVlMT0FE';
              a.download = 'probe-out.txt';
              a.click();
              return 'clicked';
            })();
            """
        } else {
            js = """
            (function(){
              var blob = new Blob(['EXPORT-PAYLOAD'], { type: 'text/plain' });
              var a = document.createElement('a');
              a.href = URL.createObjectURL(blob);
              a.download = 'probe-out.txt';
              a.click();     // 脱离文档，与脚本完全一致
              return 'clicked';
            })();
            """
        }
        webView.evaluateJavaScript(js) { _, err in
            if let err = err { note("evaluateJavaScript error: \(err)") }
        }
    }

    // MARK: WKScriptMessageHandler
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let body = m.body as? [String: Any], let k = body["k"] as? String {
            note("MSG: \(k)")
        }
    }

    // MARK: WKNavigationDelegate
    func webView(_ w: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            note("POLICY: shouldPerformDownload=true → .download")
            downloadEntered = true
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ w: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            note("POLICY(response): canShowMIMEType=false → .download")
            downloadEntered = true
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        note("didBecome download (navigationAction)")
        downloads[ObjectIdentifier(download)] = self
        download.delegate = self
    }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        note("didBecome download (navigationResponse)")
        downloads[ObjectIdentifier(download)] = self
        download.delegate = self
    }

    // MARK: WKDownloadDelegate
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        destinationRequested = true
        let dir = URL(fileURLWithPath: "/tmp/dlprobe/out", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("probe-out.txt")
        try? FileManager.default.removeItem(at: target)
        note("DECIDE-DESTINATION suggested=\(suggestedFilename) → \(target.path)")
        completionHandler(target)
    }
    func downloadDidFinish(_ download: WKDownload) {
        savedPath = "/tmp/dlprobe/out/probe-out.txt"
        note("downloadDidFinish")
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        note("downloadFailed: \(error.localizedDescription)")
    }
}

let shimOn = CommandLine.arguments.contains("--shim")
let kindArg = CommandLine.arguments.first(where: { $0.hasPrefix("--kind=") }).map { String($0.dropFirst(7)) } ?? "blob"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe()
probe.kind = kindArg
probe.start(shim: shimOn)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { probe.fire() }
DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
    let out = "/tmp/dlprobe/out/probe-out.txt"
    let exists = FileManager.default.fileExists(atPath: out)
    note("---- 结论 (shim=\(shimOn), kind=\(kindArg)) ----")
    note("WebKit 进入下载通道: \(probe.downloadEntered)")
    note("下载目的地被询问: \(probe.destinationRequested)")
    note("文件落盘: \(exists)" + (exists ? " 内容=\((try? String(contentsOfFile: out, encoding: .utf8)) ?? "?")" : ""))
    dump()
    exit(0)
}
app.run()
