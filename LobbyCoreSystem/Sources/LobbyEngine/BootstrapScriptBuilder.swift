import Foundation
import LobbyDomain

/// 页面引导脚本构建器。
///
/// 脚本在 `atDocumentStart` 注入，职责按顺序：
/// 1. `window.<instanceGlobalName>`：实例参数（认证响应、清单、帧率、画质、多开口径）；
/// 2. `jsb.reflection.callStaticMethod` 垫片：把 HSDK 的原生调用路由到页面桥；
/// 3. XHR 拦截：`/login/authuser` 用预认证响应字节应答，其余请求直连网络；
/// 4. 全局错误 / Promise 拒绝桥接回原生；
/// 5. console 桥接（页面日志回传原生统一落日志）。
///
/// ⚠️ 字段名与页面侧硬编码契约逐字节对齐（见 LobbyConfiguration 页面桥契约注释），
/// 改名即静默失效。
public enum BootstrapScriptBuilder {
    public struct Configuration: Sendable {
        public let instanceID: String
        public let accountName: String
        public let authResponseBase64: String
        public let manifestJSON: String
        public let frameRate: Int
        public let qualityRawValue: String
        public let instanceCount: Int

        public init(instanceID: String,
                    accountName: String,
                    authResponseBase64: String,
                    manifestJSON: String,
                    frameRate: Int,
                    qualityRawValue: String,
                    instanceCount: Int) {
            self.instanceID = instanceID
            self.accountName = accountName
            self.authResponseBase64 = authResponseBase64
            self.manifestJSON = manifestJSON
            self.frameRate = frameRate
            self.qualityRawValue = qualityRawValue
            self.instanceCount = instanceCount
        }
    }

    public static func makeScript(configuration: Configuration) -> String {
        let global = LobbyConfiguration.instanceGlobalName
        let channel = LobbyConfiguration.webChannelName
        // 清单 JSON 原样内嵌（已经是合法 JSON 对象文本）。
        let manifestValue = configuration.manifestJSON.isEmpty ? "{}" : configuration.manifestJSON
        return """
        window.\(global) = {
          id: \(jsonString(configuration.instanceID)),
          account: \(jsonString(configuration.accountName)),
          authResponse: \(jsonString(configuration.authResponseBase64)),
          frameRate: \(configuration.frameRate),
          qualitySingle: '\(configuration.qualityRawValue)',
          qualityMulti: '\(configuration.qualityRawValue)',
          // macOS 矩阵格子是可缩放多开画面，同时启用 WebRuntime 的 EXACT_FIT 适配策略。
          multiOpen: true,
          instanceCount: \(configuration.instanceCount),
          startupMode: 'serial',
          scripts: [],
          manifest: \(manifestValue),
        };
        window.jsb = window.jsb || {};
        window.jsb.reflection = window.jsb.reflection || {};
        window.jsb.reflection.callStaticMethod = function() {
          var args = Array.prototype.slice.call(arguments), klass = args.shift(), method = args.shift();
          if (klass === 'IOS2Native' && method === 'runtimeBackend') return 'webkit';
          // HSDK 只在 cc.sys 报告 iOS 时选 iOS 类；macOS WebKit 页面报告 macOS，
          // 同一份 SDK 会退到 Android 风格的类/方法对然后静默消失。这里同时接受
          // 两套入口，载荷格式完全一致。
          var hsdkClasses = \(hsdkClassSetJSON);
          if (hsdkClasses[klass]) {
            var hsdkMessage = method === 'receiveMsgFromHSDK' ? args[1] : args[1];
            try { window.webkit.messageHandlers.\(channel).postMessage({type:'hsdk', instance: window.\(global).id, message: String(hsdkMessage || '{}')}); } catch (error) { console.error(error); }
          }
          return null;
        };
        var __authBuffer = null;
        function __authBytes() {
          if (__authBuffer) return __authBuffer.slice(0);
          var binary = atob(window.\(global).authResponse || ''), bytes = new Uint8Array(binary.length);
          for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          __authBuffer = bytes.buffer;
          window.\(global).authResponse = '';
          return __authBuffer.slice(0);
        }
        var __nativeXHR = window.XMLHttpRequest;
        function __bridgedXHR() {
          this._native = new __nativeXHR(); this._fake = false; this._readyState = 0; this._status = 0;
          this._response = null; this._responseType = ''; this._listeners = {};
          var self = this;
          ['readystatechange','load','error','timeout','abort','loadend','progress'].forEach(function(type) {
            self._native['on' + type] = function(event) { self._emit(type, event); };
          });
        }
        __bridgedXHR.prototype.open = function(method, url) {
          this._fake = /\\/login\\/authuser(?:\\?|$)/.test(String(url || ''));
          if (this._fake) { this._readyState = 1; this._emit('readystatechange'); }
          else this._native.open.apply(this._native, arguments);
        };
        __bridgedXHR.prototype.send = function(body) {
          if (!this._fake) return this._native.send(body);
          var self = this; setTimeout(function() {
            self._status = 200; self._response = __authBytes();
            self._readyState = 2; self._emit('readystatechange');
            self._readyState = 3; self._emit('readystatechange');
            self._readyState = 4; self._emit('readystatechange'); self._emit('load'); self._emit('loadend');
          }, 0);
        };
        __bridgedXHR.prototype.abort = function() { if (this._fake) { this._readyState = 0; this._emit('abort'); this._emit('loadend'); } else this._native.abort(); };
        __bridgedXHR.prototype.setRequestHeader = function(name, value) { if (!this._fake) this._native.setRequestHeader(name, value); };
        __bridgedXHR.prototype.getAllResponseHeaders = function() { return this._fake ? 'Content-Type: application/octet-stream\\r\\n' : this._native.getAllResponseHeaders(); };
        __bridgedXHR.prototype.getResponseHeader = function(name) { return this._fake && String(name).toLowerCase() === 'content-type' ? 'application/octet-stream' : (this._fake ? null : this._native.getResponseHeader(name)); };
        __bridgedXHR.prototype.overrideMimeType = function(value) { if (!this._fake && this._native.overrideMimeType) this._native.overrideMimeType(value); };
        __bridgedXHR.prototype.addEventListener = function(type, listener) { if (typeof listener === 'function') (this._listeners[type] || (this._listeners[type] = [])).push(listener); };
        __bridgedXHR.prototype.removeEventListener = function(type, listener) { var list = this._listeners[type] || [], index = list.indexOf(listener); if (index >= 0) list.splice(index, 1); };
        __bridgedXHR.prototype._emit = function(type, event) { event = event || {type:type, target:this}; var handler = this['on' + type]; if (typeof handler === 'function') handler.call(this, event); var list = (this._listeners[type] || []).slice(); for (var i = 0; i < list.length; i++) list[i].call(this, event); };
        Object.defineProperties(__bridgedXHR.prototype, {
          readyState:{get:function(){return this._fake ? this._readyState : this._native.readyState;}},
          status:{get:function(){return this._fake ? this._status : this._native.status;}},
          statusText:{get:function(){return this._fake ? 'OK' : this._native.statusText;}},
          response:{get:function(){return this._fake ? this._response : this._native.response;}},
          responseText:{get:function(){return this._fake ? '' : this._native.responseText;}},
          responseType:{get:function(){return this._fake ? this._responseType : this._native.responseType;},set:function(value){this._responseType=value||'';if(!this._fake)this._native.responseType=value;}},
          timeout:{get:function(){return this._native.timeout;},set:function(value){this._native.timeout=value;}},
          withCredentials:{get:function(){return this._fake ? false : this._native.withCredentials;},set:function(value){if(!this._fake)this._native.withCredentials=value;}}
        });
        __bridgedXHR.UNSENT = 0; __bridgedXHR.OPENED = 1; __bridgedXHR.HEADERS_RECEIVED = 2; __bridgedXHR.LOADING = 3; __bridgedXHR.DONE = 4;
        window.XMLHttpRequest = __bridgedXHR;
        window.addEventListener('error', function(event) {
          try { window.webkit.messageHandlers.\(channel).postMessage({type:'error', instance:window.\(global).id, message:String(event.error && event.error.stack || event.message || 'Web game error')}); } catch (ignored) {}
        });
        window.addEventListener('unhandledrejection', function(event) {
          try { window.webkit.messageHandlers.\(channel).postMessage({type:'error', instance:window.\(global).id, message:String(event.reason && event.reason.stack || event.reason || 'Unhandled rejection')}); } catch (ignored) {}
        });
        \(consoleBridgeScript)
        """
    }

    /// HSDK 类白名单（JS 对象字面量，用于 `hsdkClasses[klass]` 查找）。
    /// 用 JSONSerialization 生成，避免手写转义出错（键一旦损坏，HSDK 消息
    /// 不会报错地静默丢失，表现为卡在平台登录）。
    private static var hsdkClassSetJSON: String {
        let keys = Array(LobbyConfiguration.hsdkBridgeClasses)
        guard let data = try? JSONSerialization.data(
            withJSONObject: Dictionary(uniqueKeysWithValues: keys.map { ($0, true) })) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// console 桥：页面日志按等级回传原生（统一落 LobbyLog）。
    public static let consoleBridgeScript: String = {
        let channel = LobbyConfiguration.webChannelName
        return """
        (function () {
          var channel = '\(channel)';
          var levels = { log: 'debug', info: 'info', warn: 'warn', error: 'error', debug: 'verbose' };
          function post(level, args) {
            try {
              var parts = [];
              for (var i = 0; i < args.length; i++) {
                var item = args[i];
                parts.push(typeof item === 'string' ? item : (item && item.stack ? String(item.stack) : String(item)));
              }
              window.webkit.messageHandlers[channel].postMessage({ type: 'console', level: level, message: parts.join(' ') });
            } catch (ignored) {}
          }
          var native = {};
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function (method) {
            native[method] = console[method] ? console[method].bind(console) : function () {};
            console[method] = function () {
              try { post(levels[method], arguments); } catch (ignored) {}
              native[method].apply(console, arguments);
            };
          });
        })();
        """
    }()

    /// Swift 字符串 → JSON 字符串字面量。
    private static func jsonString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let literal = String(data: data, encoding: .utf8) else { return "\u{22}\u{22}" }
        return literal
    }
}
