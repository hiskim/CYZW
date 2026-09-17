import Foundation
import LobbyDomain

/// 页面引导脚本构建器。
///
/// 脚本在 `atDocumentStart` 注入，职责按顺序：
/// 1. `window.<instanceGlobalName>`：实例参数（认证响应、清单、帧率、画质、多开口径）；
/// 2. `jsb.reflection.callStaticMethod` 垫片：把 HSDK 的原生调用路由到页面桥；
/// 3. XHR 拦截：`/login/authuser` 交给**登录代理**（请求体上报原生 → 原生按
///    `serverId` 现算应答 → `window.__LOBBY_LOGIN__.complete()` 回填），其余请求直连网络；
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
        /// 凭据本体（base64）。用于给「体必须是凭据」的那几个 `/login/*` 端点换体
        /// （目前是 `/login/serverlist`）。空串 = 不做替换（退回原样放行）。
        public let credentialBase64: String
        /// 与上面那份凭据匹配的 `O4e-Encoding` 值（nil = 不发这个头）。
        public let credentialEncoding: String?
        /// 游戏服务端 origin（如 `https://xxz-xyzw.hortorgames.com`）。
        /// 页面侧的 `serverList` 兜底要自己发 HTTP 请求，需要它。
        public let serverOrigin: String

        public init(instanceID: String,
                    accountName: String,
                    authResponseBase64: String,
                    manifestJSON: String,
                    frameRate: Int,
                    qualityRawValue: String,
                    instanceCount: Int,
                    credentialBase64: String = "",
                    credentialEncoding: String? = nil,
                    serverOrigin: String = "") {
            self.instanceID = instanceID
            self.accountName = accountName
            self.authResponseBase64 = authResponseBase64
            self.manifestJSON = manifestJSON
            self.frameRate = frameRate
            self.qualityRawValue = qualityRawValue
            self.instanceCount = instanceCount
            self.credentialBase64 = credentialBase64
            self.credentialEncoding = credentialEncoding
            self.serverOrigin = serverOrigin
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
          // 凭据本体（base64）。`/login/serverlist` 只认「体 = 凭据本身」——
          // 游戏自己发的是参数体，服务端会回一个空的 200（实测 105 字节 / 0 区 0 角色），
          // 「选择大区」因此永远是空的。垫片用这份字节把那类请求的体换掉。
          credential: \(jsonString(configuration.credentialBase64)),
          credentialEncoding: \(jsonString(configuration.credentialEncoding ?? "")),
          serverOrigin: \(jsonString(configuration.serverOrigin)),
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
        \(consoleBridgeScript)
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
        function __toBase64(body) {
          if (!body) return '';
          var view = null;
          if (body instanceof ArrayBuffer) view = new Uint8Array(body);
          else if (body && body.buffer) view = new Uint8Array(body.buffer, body.byteOffset || 0, body.byteLength || 0);
          if (!view || !view.length) return '';
          var parts = [], chunk = 0x8000;
          for (var i = 0; i < view.length; i += chunk) {
            parts.push(String.fromCharCode.apply(null, view.subarray(i, i + chunk)));
          }
          return btoa(parts.join(''));
        }
        function __fromBase64(text) {
          if (!text) return null;
          var binary = atob(text), bytes = new Uint8Array(binary.length);
          for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          return bytes.buffer;
        }
        // 登录代理：游戏的 login_authuser 请求体里带着它想去哪个区（serverId），
        // 宿主据此现算应答 —— 这才是「游戏内选区」能生效的关键。
        // 从前这里是无状态地一律回预认证字节，于是选区永远回到原角色。
        var __loginSeq = 0, __loginPending = {}, __loginTimeoutMs = 15000, __loginSeen = {};
        // 凭据本体：`/login/serverlist` 只认「体 = 凭据本身」。游戏发的是参数体，
        // 服务端会回一个**空的 200**（实测 105 字节 / 0 区 / 0 角色），
        // 「设置 → 服务器 → 选择大区」因此永远是空的。
        var __credentialBytes = null;
        (function () {
          var base64 = window.\(global).credential || '';
          if (!base64) { console.warn('[lobby] 没有注入凭据本体（/login/serverlist 只能原样放行）'); return; }
          try {
            var binary = atob(base64), bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            __credentialBytes = bytes;
            console.warn('[lobby] 凭据本体已注入：' + bytes.length + ' 字节，编码头='
              + (window.\(global).credentialEncoding || '（不发）'));
          } catch (error) { console.error('[lobby] 凭据解码失败', error); }
          window.\(global).credential = '';
        })();
        // 诊断计数：这条链路出问题时界面只是「空着」，没有异常可看，
        // 所以把「有没有发过 / 走的哪条通道」记下来，由原生在 didFinish 后主动取。
        var __loginStats = { authXHR: 0, credentialXHR: 0, passthroughLoginXHR: 0,
                             passthroughPaths: [], parseHooked: false, wsLoginCmds: [] };
        // WS 嗅探：帧是 BON + 单字节 XOR（密钥在头 4 字节里），所以对 2..249 逐把钥匙试一遍，
        // 看解密后有没有 `login_xxx` —— 只要 1KB 级的字节，代价可以忽略。
        // 目的：确认 `login_serverlist` 到底走的是 HTTP 还是 WS。
        (function () {
          var proto = window.WebSocket && window.WebSocket.prototype;
          if (!proto || !proto.send || proto.__lobbySniffed) return;
          var originalSend = proto.send;
          function sniff(data) {
            try {
              var bytes = null;
              if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
              else if (data && data.buffer) bytes = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength || 0);
              else if (typeof data === 'string') {
                var m = /login_[a-z]+/.exec(data);
                if (m) __loginStats.wsLoginCmds.push(m[0] + '(text)');
                return;
              }
              if (!bytes || bytes.length < 8) return;
              for (var key = 2; key <= 249; key++) {
                var text = '';
                for (var i = 4; i < Math.min(bytes.length, 96); i++) {
                  text += String.fromCharCode((bytes[i] ^ key) & 0xff);
                }
                var found = /login_[a-z]+/.exec(text);
                if (found) {
                  __loginStats.wsLoginCmds.push(found[0] + '(' + bytes.length + 'B)');
                  console.warn('[lobby] WS 上出现 ' + found[0] + ' 命令（' + bytes.length + ' 字节）');
                  break;
                }
              }
            } catch (ignored) {}
          }
          proto.send = function (data) { sniff(data); return originalSend.apply(this, arguments); };
          proto.__lobbySniffed = true;
        })();
        window.__LOBBY_LOGIN__ = {
          pending: __loginPending,
          credentialBytes: function () { return __credentialBytes ? __credentialBytes.length : 0; },
          stats: function () {
            return JSON.stringify(__loginStats);
          },
          complete: function (requestId, base64, source) {
            var xhr = __loginPending[requestId];
            if (!xhr) return false;
            delete __loginPending[requestId];
            if (xhr.__lobbyTimer) { clearTimeout(xhr.__lobbyTimer); xhr.__lobbyTimer = null; }
            var bytes = __fromBase64(base64);
            if (!bytes || bytes.byteLength < 5) bytes = __authBytes();
            xhr.__lobbyFinish(200, bytes, source || 'native');
            return true;
          },
          status: function () { return 'pending=' + Object.keys(__loginPending).length; }
        };
        var __nativeXHR = window.XMLHttpRequest;
        function __bridgedXHR() {
          this._native = new __nativeXHR(); this._fake = false; this._credential = false;
          this._readyState = 0; this._status = 0;
          this._response = null; this._responseType = ''; this._listeners = {};
          this._loginSource = ''; this.__lobbyTimer = null;
          var self = this;
          ['readystatechange','load','error','timeout','abort','loadend','progress'].forEach(function(type) {
            self._native['on' + type] = function(event) { self._emit(type, event); };
          });
        }
        __bridgedXHR.prototype.open = function(method, url) {
          // ⚠️ 整个函数**绝不能抛**：它垫在游戏所有 XHR 的 open 上，抛一次就可能把
          // 游戏的加载任务打断（表现是卡在「正在加载游戏场景」，而且完全没有报错）。
          // 诊断/统计代码尤其危险——之前就因为统计字段没初始化，把它变成了异常源。
          try {
            var target = String(url || '');
            this._fake = /\\/login\\/authuser(?:\\?|$)/.test(target);
            // 「体必须是凭据」的端点：真 XHR 照常 open（URL / 方法 / _seq 全原样），
            // 只在 send 时把 body 与编码头换掉。事件继续由 _native 转发。
            this._credential = !this._fake && !!__credentialBytes
              && /\\/login\\/serverlist(?:\\?|$)/.test(target);
            // 诊断：还有哪些 `/login/*` 没被接管。单独一层 try——统计出问题不该影响分类结果。
            try {
              if (this._fake) __loginStats.authXHR++;
              else if (this._credential) __loginStats.credentialXHR++;
              else {
                var match = /\\/login\\/([a-z]+)/.exec(target);
                if (match) {
                  __loginStats.passthroughLoginXHR++;
                  if (__loginStats.passthroughPaths.indexOf(match[1]) < 0) {
                    __loginStats.passthroughPaths.push(match[1]);
                  }
                  if (!__loginSeen[match[1]]) {
                    __loginSeen[match[1]] = true;
                    console.warn('[lobby] 未接管的 /login/' + match[1] + '（体是游戏参数，服务端可能只回空）');
                  }
                }
              }
            } catch (statsError) { console.error('[lobby] 统计失败（不影响请求）', statsError); }
            if (this._fake) { this._readyState = 1; this._emit('readystatechange'); }
            else this._native.open.apply(this._native, arguments);
          } catch (error) {
            console.error('[lobby] XHR open 垫片异常，降级为原样放行', error);
            try { this._fake = false; this._credential = false; this._native.open.apply(this._native, arguments); } catch (ignored) {}
          }
        };
        __bridgedXHR.prototype.send = function(body) {
          if (this._credential) {
            try {
              this._native.setRequestHeader('Content-Type', 'application/octet-stream');
              var encoding = window.\(global).credentialEncoding;
              if (encoding) this._native.setRequestHeader('O4e-Encoding', encoding);
            } catch (error) { console.error('[lobby] 设置凭据请求头失败', error); }
            console.warn('[lobby] /login/serverlist 改用凭据体（' + __credentialBytes.length
              + ' 字节；游戏给的参数体服务端只回空列表）');
            // 回执：这条到底是成功了还是又拿了个空货，一眼可见。
            var self = this;
            this.addEventListener('loadend', function () {
              try {
                var response = self._native.response;
                var size = response ? (response.byteLength || 0) : 0;
                console.warn('[lobby] /login/serverlist 完成：status=' + self._native.status
                  + ' 响应 ' + size + ' 字节' + (size < 4096 ? '（太小，八成还是空的）' : ''));
              } catch (ignored) {}
            });
            return this._native.send(__credentialBytes.buffer);
          }
          if (!this._fake) return this._native.send(body);
          var self = this;
          var requestId = 'q' + (++__loginSeq);
          self.__lobbyFinish = function (status, bytes, source) {
            self._status = status; self._response = bytes; self._loginSource = source || '';
            self._readyState = 2; self._emit('readystatechange');
            self._readyState = 3; self._emit('readystatechange');
            self._readyState = 4; self._emit('readystatechange');
            self._emit('load'); self._emit('loadend');
          };
          __loginPending[requestId] = self;
          var payload = '';
          try { payload = __toBase64(body); } catch (error) { payload = ''; }
          try {
            window.webkit.messageHandlers.\(channel).postMessage({
              type: 'loginAuth', instance: window.\(global).id,
              requestId: requestId, body: payload
            });
          } catch (error) {
            // 桥不可用（页面跑在别的宿主里）：退回预认证字节，与本改造之前完全一致。
            delete __loginPending[requestId];
            console.error(error);
            self.__lobbyFinish(200, __authBytes(), 'bridge-unavailable');
            return;
          }
          // 原生没在预算内应答：同样退回预认证字节。
          // 宁可回到原区服，也绝不让登录卡死在这里。
          self.__lobbyTimer = setTimeout(function () {
            if (!__loginPending[requestId]) return;
            delete __loginPending[requestId];
            console.warn('[lobby] loginAuth ' + __loginTimeoutMs + 'ms 未应答，退回预认证字节');
            self.__lobbyFinish(200, __authBytes(), 'timeout');
          }, __loginTimeoutMs);
        };
        __bridgedXHR.prototype.abort = function() {
          if (this._fake) {
            if (this.__lobbyTimer) { clearTimeout(this.__lobbyTimer); this.__lobbyTimer = null; }
            for (var key in __loginPending) { if (__loginPending[key] === this) delete __loginPending[key]; }
            this._readyState = 0; this._emit('abort'); this._emit('loadend');
          } else this._native.abort();
        };
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
        // ── 补上游戏解析器需要、而服务端响应里没有的两个字段 ──
        //
        // 实测：`/login/serverlist` 的响应只有
        //   `areaList, serverList, roleCount, recommendId, roles`
        // 而游戏侧 `SelectServerModule._parseFirstServerList` 第一句就
        //   `i = e.deletedRoles` … 后面还有 `e.deletedRoles.forEach(...)`
        // —— 字段缺失直接抛 TypeError，于是 `bigServerList` 永远填不上，
        // 「设置 → 服务器 → 选择大区」就是一个空面板（连报错都没有）。
        // 它还依赖 `e.maxViewId`（用它枚举大区，缺了 `nameServerList` 也是空的）。
        //
        // 所以：**在数据进解析器之前补上这两个字段**。为什么打在这里而不是
        // 去打 LoginService.serverList / 自己重新解码响应：
        //   · 不用 BON 解码器（页面里没有可用的），也不用把 1.4MB 响应搬来搬去；
        //   · 请求体已经被上面那层换成了凭据（实测确实生效），数据本来就是对的；
        //   · 锚点 `SelectServerModule` 是游戏模块表里的**短名**（已验证存在），
        //     原型上的两个解析方法就是数据入口，补在最靠近消费方的地方最不容易碎。
        //
        // 三条安全线：找不到模块 / 方法不是函数 / 已经打过补丁 → 什么都不做。
        (function () {
          var done = false, tries = 0;
          var timer = setInterval(function () {
            if (done) { clearInterval(timer); return; }
            if (++tries > 120) {
              clearInterval(timer);
              console.warn('[lobby] 未能挂上 SelectServerModule（轮询 60s 放弃，选择大区会是空的）');
              return;
            }
            var requireFn = window.__require;
            if (typeof requireFn !== 'function') return;
            var klass = null;
            try {
              var module = requireFn('SelectServerModule');
              klass = module && (module.SelectServerModule || module.default || module);
            } catch (ignored) {}
            if (!klass || !klass.prototype) return;
            var names = ['_parseFirstServerList', '_parseServerList'];
            var patched = 0;
            for (var index = 0; index < names.length; index++) {
              (function (name) {
                var original = klass.prototype[name];
                if (typeof original !== 'function' || original.__lobbyPatched) return;
                function patchedParser(data) {
                  try {
                    if (data && typeof data === 'object') {
                      // 游戏自己按 Map 用（`0 < i.size` / `i.forEach`），给空对象会二次抛。
                      if (!data.deletedRoles) data.deletedRoles = new Map();
                      if (data.maxViewId === undefined) {
                        var max = 0, list = data.serverList || [];
                        for (var i = 0; i < list.length; i++) {
                          var view = list[i] && list[i].viewId;
                          if (typeof view === 'number' && view > max) max = view;
                        }
                        data.maxViewId = max;
                      }
                      __loginStats.parsedServers = (data.serverList || []).length;
                    }
                  } catch (ignored) {}
                  return original.apply(this, arguments);
                }
                patchedParser.__lobbyPatched = true;
                klass.prototype[name] = patchedParser;
                patched++;
              })(names[index]);
            }
            done = true;
            if (patched > 0) {
              __loginStats.parseHooked = true;
              console.warn('[lobby] SelectServerModule 解析补丁已挂上（' + patched + ' 个方法）');
            } else {
              console.warn('[lobby] SelectServerModule 上没找到可打的解析方法');
            }
          }, 500);
        })();
        window.addEventListener('error', function(event) {
          try { window.webkit.messageHandlers.\(channel).postMessage({type:'error', instance:window.\(global).id, message:String(event.error && event.error.stack || event.message || 'Web game error')}); } catch (ignored) {}
        });
        window.addEventListener('unhandledrejection', function(event) {
          try { window.webkit.messageHandlers.\(channel).postMessage({type:'error', instance:window.\(global).id, message:String(event.reason && event.reason.stack || event.reason || 'Unhandled rejection')}); } catch (ignored) {}
        });
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
