/* Runtime compatibility layer for imported third-party scripts. */
(function (global) {
    'use strict';

    // 页面桥通道名：与 LobbyConfiguration.webChannelName / 页面侧
    // `webkit.messageHandlers.ios2Game` 是同一份外部契约，改名即静默失效。
    var WEB_CHANNEL = 'ios2Game';

    var runtime = {
        _installed: false,
        _executed: {},
        // 本层自己创建、需要在 reset 时收回的全局符号。
        _ownedSocketAliases: [],
        _ownedBridge: false,
        _roleSyncTimer: null,
        _environmentTimer: null,
        _mirroredSockets: [],
        // 宿主形态开关。
        // - 同页（macOS 大厅把脚本注入游戏页）：不需要把 socket 入站消息镜像给
        //   另一个 WebView，也没有原生侧代理游戏模块 / 协议编码。
        // - 覆盖 WebView（旧架构，ios2-script-page.js 走 waitForGame）：两者都要开。
        // waitForGame 只被覆盖 WebView 那条路径调用，因此在那里打开即可。
        _mirrorInbound: false,
        _forwardRoleToNative: false,
        // 游戏加载器探测的失败计数（见 _readRole / refreshGlobals）。
        _roleLookupFailures: 0,
        _gUtilsUnavailable: false,

        _ensureElement: function (element) {
            if (!element) return element;
            if (element.style && typeof element.style.setProperty !== 'function') {
                element.style.setProperty = function (name, value) { this[name] = value; };
            }
            if (element.style && typeof element.style.removeProperty !== 'function') {
                element.style.removeProperty = function (name) { delete this[name]; };
            }
            if (typeof element.remove !== 'function') {
                element.remove = function () {
                    var parent = this.parentNode || this.parentElement;
                    if (parent && typeof parent.removeChild === 'function') parent.removeChild(this);
                };
            }
            if (typeof element.click !== 'function') {
                element.click = function () {
                    var handler = this.onclick;
                    if (typeof handler === 'function') handler.call(this, { target: this });
                };
            }
            if (typeof element.getBoundingClientRect !== 'function') {
                element.getBoundingClientRect = function () {
                    var width = Number(this.offsetWidth || this.clientWidth || 0);
                    var height = Number(this.offsetHeight || this.clientHeight || 0);
                    return { left: 0, top: 0, right: width, bottom: height, width: width, height: height };
                };
            }
            if (!element.classList) {
                element.classList = {
                    add: function (name) {
                        var names = String(element.className || '').split(/\s+/).filter(Boolean);
                        if (names.indexOf(name) < 0) names.push(name);
                        element.className = names.join(' ');
                    },
                    remove: function (name) {
                        element.className = String(element.className || '').split(/\s+/)
                            .filter(function (item) { return item && item !== name; }).join(' ');
                    },
                    contains: function (name) {
                        return String(element.className || '').split(/\s+/).indexOf(name) >= 0;
                    }
                };
            }
            return element;
        },

        _patchDom: function () {
            var document = global.document;
            if (!document || document.__ios2RuntimePatched) return;
            var originalCreate = document.createElement;
            var originalById = document.getElementById;
            var originalQuery = document.querySelector;
            var originalQueryAll = document.querySelectorAll;
            if (typeof originalCreate === 'function') {
                document.createElement = function () {
                    return runtime._ensureElement(originalCreate.apply(this, arguments));
                };
            }
            if (typeof originalById === 'function') {
                document.getElementById = function () {
                    return runtime._ensureElement(originalById.apply(this, arguments));
                };
            }
            if (typeof originalQuery === 'function') {
                document.querySelector = function () {
                    return runtime._ensureElement(originalQuery.apply(this, arguments));
                };
            }
            if (typeof originalQueryAll === 'function') {
                document.querySelectorAll = function () {
                    var result = originalQueryAll.apply(this, arguments) || [];
                    for (var index = 0; index < result.length; index++) runtime._ensureElement(result[index]);
                    return result;
                };
            }
            runtime._ensureElement(document.body);
            runtime._ensureElement(document.head);
            document.__ios2RuntimePatched = true;
        },

        // 第三方脚本按名字探测游戏连接，五个别名得一次给全（对齐参考实现）：
        // window.ws / gameWs / gameSocket / WebSocketClient / h5websocket(.ws)。
        // 只补 window.ws 不够——脚本表里这些名字都出现过，缺哪个都是「连接未就绪」。
        _publishSocketAliases: function (socket) {
            if (!socket) return;
            var names = ['ws', 'gameWs', 'gameSocket', 'WebSocketClient'];
            for (var index = 0; index < names.length; index++) {
                if (global[names[index]]) continue;
                try {
                    global[names[index]] = socket;
                    this._ownedSocketAliases.push(names[index]);
                } catch (ignoredWrite) {}
            }
            if (!global.h5websocket) {
                try {
                    global.h5websocket = { ws: socket };
                    this._ownedSocketAliases.push('h5websocket');
                } catch (ignoredH5) {}
            }
        },

        _patchWebSocket: function () {
            try {
                var WebSocket = global.WebSocket;
                var prototype = WebSocket && WebSocket.prototype;
                if (!prototype) return;
                var rememberSocket = function (socket) {
                    runtime._publishSocketAliases(socket);
                    runtime.refreshGlobals();
                };
                if (typeof prototype.send === 'function' && !prototype.__ios2SendPatched) {
                    var originalSend = prototype.send;
                    prototype.send = function () {
                        rememberSocket(this);
                        return originalSend.apply(this, arguments);
                    };
                    prototype.__ios2SendPatched = true;
                }
                if (typeof prototype.sendAsync === 'function' && !prototype.__ios2SendAsyncPatched) {
                    var originalSendAsync = prototype.sendAsync;
                    prototype.sendAsync = function () {
                        rememberSocket(this);
                        return originalSendAsync.apply(this, arguments);
                    };
                    prototype.__ios2SendAsyncPatched = true;
                }
            } catch (ignored) {}
        },

        // 请求编码：有真实 g_utils.bon.encode 就用它（游戏协议体是自定义编码，
        // JSON 化会被服务端丢弃）；只在它确实返回字符串时才采用，避免把
        // 对象喂给 WebSocket.send 变成 "[object Object]"。
        _encodeRequest: function (request) {
            if (typeof request === 'string') return request;
            var utils = global.g_utils;
            if (utils && utils.bon && typeof utils.bon.encode === 'function') {
                try {
                    var encoded = utils.bon.encode(request);
                    if (typeof encoded === 'string') return encoded;
                } catch (ignored) {}
            }
            try { return JSON.stringify(request); } catch (unserializable) { return String(request); }
        },

        // sendAsync 靠临时接管 socket.onmessage 匹配响应，而游戏共用同一个 socket。
        // 两个并发请求会互相抢 onmessage，所以这里串行化；还原时也只还原「还是我们
        // 装的那个 handler」，避免把游戏中途换上的处理器顶掉。
        _ensureSendAsync: function (socket) {
            if (!socket || typeof socket.sendAsync === 'function' || typeof socket.send !== 'function') return socket;
            var runtime = this;
            var queue = Promise.resolve();
            socket.sendAsync = function (request) {
                var self = this;
                var run = function () { return runtime._sendAsyncOnce(self, request); };
                var result = queue.then(run, run);
                queue = result.then(function () {}, function () {});
                return result;
            };
            return socket;
        },

        _sendAsyncOnce: function (socket, request) {
            var runtime = this;
            var originalSend = socket.send;
            return new Promise(function (resolve, reject) {
                var previous = socket.onmessage;
                var finished = false;
                var timer = null;
                var restore = function () {
                    if (socket.onmessage === handler) socket.onmessage = previous;
                };
                var finish = function (settle, value) {
                    if (finished) return;
                    finished = true;
                    if (timer) clearTimeout(timer);
                    restore();
                    settle(value);
                };
                var handler = function (event) {
                    var value = event && event.data !== undefined ? event.data : event;
                    var parsed = value;
                    if (typeof value === 'string') {
                        try { parsed = JSON.parse(value); } catch (ignored) {}
                    }
                    var requestSeq = request && request.seq;
                    var requestCmd = request && request.cmd;
                    var responseSeq = parsed && parsed.seq;
                    var responseCmd = parsed && parsed.cmd;
                    var sequenceMismatch = requestSeq !== undefined && responseSeq !== undefined && String(requestSeq) !== String(responseSeq);
                    var commandMismatch = requestCmd && responseCmd && String(requestCmd) !== String(responseCmd);
                    if (sequenceMismatch || commandMismatch) {
                        if (typeof previous === 'function') previous.call(socket, event);
                        return;
                    }
                    if (typeof previous === 'function') previous.call(socket, event);
                    finish(resolve, parsed);
                };
                timer = setTimeout(function () {
                    finish(reject, new Error('WebSocket response timeout'));
                }, 10000);
                socket.onmessage = handler;
                try {
                    originalSend.call(socket, runtime._encodeRequest(request));
                } catch (error) {
                    finish(reject, error);
                }
            });
        },

        // The game owns the real socket. Mirror its inbound messages to the
        // WKWebView without replacing the game's existing message handler.
        _mirrorSocket: function (socket) {
            if (!socket || socket.__ios2InboundMirrorInstalled) return socket;
            var runtime = this;
            var sendEvent = function (type, event) {
                try {
                    var value = event && event.data !== undefined ? event.data : event;
                    var safe = runtime._copyJSONSafe(value, 0, []);
                    if (safe === undefined && value !== undefined && value !== null) safe = String(value);
                    var message = { type: type || 'message' };
                    if (safe !== undefined) message.data = safe;
                    if (event && event.code !== undefined) message.code = Number(event.code) || 0;
                    if (event && event.reason !== undefined) message.reason = String(event.reason || '');
                    if (event && event.message !== undefined) message.message = String(event.message || '');
                    runtime._sendWebViewEvent(message);
                } catch (error) {
                    try { jsb.reflection.callStaticMethod('IOS2Native', 'trace:', 'socket mirror failed: ' + (error.message || error)); }
                    catch (ignored) {}
                }
            };
            try {
                var hasMessageProperty = ('onmessage' in socket) || socket.onmessage !== undefined;
                if (!hasMessageProperty && typeof socket.addEventListener === 'function') {
                    socket.addEventListener('message', function (event) { sendEvent('message', event); });
                    socket.addEventListener('open', function (event) { sendEvent('open', event); });
                    socket.addEventListener('close', function (event) { sendEvent('close', event); });
                    socket.addEventListener('error', function (event) { sendEvent('error', event); });
                }
                var previous = socket.onmessage;
                var mirrorHandler = function (event) {
                    try { sendEvent('message', event); } catch (ignored) {}
                    if (typeof previous === 'function') {
                        try { return previous.call(this, event); } catch (error) {
                            try { console.error('[ios2] game socket onmessage error', error); } catch (ignoredError) {}
                        }
                    }
                };
                // Custom Cocos sockets often expose only onmessage. Chaining
                // it keeps the game's handler alive while adding the mirror.
                if (hasMessageProperty || previous !== undefined || typeof socket.addEventListener !== 'function') socket.onmessage = mirrorHandler;
                socket.__ios2InboundMirrorInstalled = true;
                this._mirroredSockets.push(socket);
            } catch (error) {
                try { console.error('[ios2] unable to mirror game socket', error); } catch (ignored) {}
            }
            return socket;
        },

        _findSocket: function () {
            var candidates = [
                global.ws,
                global.h5websocket && global.h5websocket.ws,
                global.h5websocket,
                global.gameWs,
                global.WebSocketClient,
                global._ws,
                global.gameSocket,
                global.__ios2GameBridge && global.__ios2GameBridge.socket
            ];
            for (var index = 0; index < candidates.length; index++) {
                var candidate = candidates[index];
                if (candidate && (typeof candidate.sendAsync === 'function' || typeof candidate.send === 'function')) {
                    var socket = this._ensureSendAsync(candidate);
                    // 入站消息镜像（socket → 另一个 WebView 的原生桥）只有「脚本跑在
                    // 独立覆盖 WebView」的旧架构才需要。脚本与游戏同页时它只是每包
                    // 一次深拷贝 + JSON.stringify 再调用一个已被丢弃的原生方法。
                    return this._mirrorInbound ? this._mirrorSocket(socket) : socket;
                }
            }
            return null;
        },

        // ⚠️ 绝不在这里接管 / 包装 window.__require。它不是宿主的符号，而是
        // **游戏自己的跨 bundle 模块注册表**：每个 CDN bundle 的 IIFE 开头就是
        //     window.__require = function a(r, s, l) { ... }
        // 把自己挂上去，同时用 `typeof __require === 'function' && __require`
        // 捕获**上一个**加载器的引用作为父 require，串成一条链。
        // 我们一旦插进去（getter/setter 或包装函数），这条链当场就断：
        // 游戏会把我们当父 require，而宿主兜底只能给出代理桩而不是真模块
        // —— 表现就是卡死在「正在加载游戏场景」。
        // 宿主只需要「读」它：脚本要的短名（ServerData / Configs / PlatformManager /
        // GlobalSignal / ModuleManager / HeroDataView …）正好都是游戏模块表的键，
        // 由游戏自己的加载器解析得到。
        _findRequire: function () {
            if (typeof global.__require === 'function') return global.__require;
            if (typeof global.require === 'function') return global.require;
            return null;
        },

        _mirrorSignals: function (requireFn) {
            if (!requireFn) return;
            // 信号镜像只服务于「脚本跑在独立覆盖 WebView」的旧架构。
            // 同页形态下给每条信号多加一次注定被丢弃的原生调用，纯负担。
            if (!this._mirrorInbound) return;
            try {
                var module = requireFn('GlobalSignal');
                var bus = module && (module.GlobalSignal || module.default || module);
                if (!bus || bus.__ios2SignalMirrorInstalled) return;
                var runtime = this;
                var wrap = function (method) {
                    if (typeof bus[method] !== 'function') return;
                    var original = bus[method];
                    bus[method] = function (name) {
                        var args = Array.prototype.slice.call(arguments, 1);
                        var result = original.apply(this, arguments);
                        try {
                            var safeArgs = runtime._copyJSONSafe(args, 0, []);
                            runtime._sendWebViewEvent({ type: 'signal', name: String(name), args: safeArgs || [] });
                        } catch (ignored) {}
                        return result;
                    };
                };
                if (typeof bus.emit === 'function') wrap('emit');
                else if (typeof bus.dispatch === 'function') wrap('dispatch');
                else wrap('dispatchEvent');
                bus.__ios2SignalMirrorInstalled = true;
            } catch (ignored) {}
        },

        // ROLE can contain engine objects and circular references. Only send a
        // bounded JSON snapshot across Cocos JSB -> Native -> WKWebView.
        _copyJSONSafe: function (value, depth, seen) {
            if (value === null || value === undefined || typeof value === 'string' ||
                typeof value === 'boolean') return value;
            if (typeof value === 'number') return isFinite(value) ? value : null;
            if (typeof value === 'function' || depth > 4) return undefined;
            seen = seen || [];
            if (seen.indexOf(value) >= 0) return undefined;
            seen.push(value);
            if (Array.isArray(value)) {
                var array = [];
                for (var arrayIndex = 0; arrayIndex < Math.min(value.length, 500); arrayIndex++) {
                    var arrayValue = this._copyJSONSafe(value[arrayIndex], depth + 1, seen);
                    if (arrayValue !== undefined) array.push(arrayValue);
                }
                return array;
            }
            var object = {};
            var keys;
            try { keys = Object.keys(value); } catch (ignored) { return undefined; }
            for (var keyIndex = 0; keyIndex < Math.min(keys.length, 300); keyIndex++) {
                var key = keys[keyIndex];
                var child;
                try { child = this._copyJSONSafe(value[key], depth + 1, seen); }
                catch (ignoredChild) { child = undefined; }
                if (child !== undefined) object[key] = child;
            }
            return object;
        },

        _copyStorage: function () {
            var result = {};
            var stores = [global.localStorage, global.cc && global.cc.sys && global.cc.sys.localStorage];
            for (var storeIndex = 0; storeIndex < stores.length; storeIndex++) {
                var store = stores[storeIndex];
                if (!store || typeof store.getItem !== 'function') continue;
                try {
                    var length = Number(store.length) || 0;
                    for (var index = 0; index < length; index++) {
                        var key = typeof store.key === 'function' ? store.key(index) : null;
                        if (key === null || key === undefined) continue;
                        var value = store.getItem(key);
                        if (value !== null && value !== undefined) result[String(key)] = String(value);
                    }
                } catch (ignored) {}
            }
            return result;
        },

        install: function () {
            if (this._installed) return;
            this._installed = true;
            // Browser userscript managers provide this alias. Keep the imported
            // source unchanged and expose the same meaning in Cocos JSB.
            if (!global.unsafeWindow) global.unsafeWindow = global;
            this._patchDom();
            this._patchWebSocket();
            this._installGMApi();
            this.refreshGlobals();
            // install() 之前只有「跑一次 refreshGlobals」：在 atDocumentStart 那一刻
            // 游戏还没建 socket、也没登录，环境探测全落空，之后没有任何重试。
            // 这里补一条有界轮询（1s × 60），socket / 模块 / ROLE 谁先就绪谁先接上。
            this.startRoleSync();
            this._startEnvironmentPolling();
        },

        // 有界环境轮询：直到 socket 与模块入口都就绪，或 60s 超时。
        _startEnvironmentPolling: function () {
            if (this._environmentTimer) return;
            var runtime = this;
            var attempts = 0;
            var poll = function () {
                var environment = runtime.refreshGlobals();
                runtime.syncRole();
                attempts++;
                var ready = !!(environment.socket && environment.require);
                if (ready || attempts > 60) runtime._stopEnvironmentPolling();
            };
            poll();
            this._environmentTimer = setInterval(poll, 1000);
        },

        _stopEnvironmentPolling: function () {
            if (this._environmentTimer) {
                clearInterval(this._environmentTimer);
                this._environmentTimer = null;
            }
        },

        // 油猴 API 垫片：第三方脚本普遍用它做导出 / 打开链接，宿主不给就等于没这功能。
        _installGMApi: function () {
            if (typeof global.GM_xmlhttpRequest !== 'function') {
                global.GM_xmlhttpRequest = function (options) {
                    var request = options || {};
                    var controller = typeof AbortController === 'function' ? new AbortController() : null;
                    var timer = null;
                    if (controller && Number(request.timeout) > 0) {
                        timer = setTimeout(function () { controller.abort(); }, Number(request.timeout));
                    }
                    var settle = function () { if (timer) clearTimeout(timer); };
                    fetch(String(request.url || ''), {
                        method: String(request.method || 'GET').toUpperCase(),
                        headers: request.headers || {},
                        body: request.data,
                        signal: controller ? controller.signal : undefined
                    }).then(function (response) {
                        return response.text().then(function (text) {
                            settle();
                            if (typeof request.onload === 'function') {
                                request.onload({ status: response.status, statusText: response.statusText,
                                                 responseText: text, response: text, finalUrl: response.url });
                            }
                        });
                    }, function (error) {
                        settle();
                        if (error && error.name === 'AbortError' && typeof request.ontimeout === 'function') request.ontimeout(error);
                        else if (typeof request.onerror === 'function') request.onerror(error);
                    });
                    return { abort: function () { if (controller) controller.abort(); } };
                };
            }
            if (typeof global.GM_download !== 'function') {
                global.GM_download = function (details) {
                    var options = typeof details === 'string' ? { url: details } : (details || {});
                    var name = String(options.name || 'download');
                    var revoke = null;
                    fetch(String(options.url || '')).then(function (response) { return response.blob(); })
                        .then(function (blob) {
                            var objectURL = URL.createObjectURL(blob);
                            var link = global.document.createElement('a');
                            link.href = objectURL;
                            link.download = name;
                            link.style.display = 'none';
                            global.document.body.appendChild(link);
                            link.click();
                            global.document.body.removeChild(link);
                            revoke = setTimeout(function () { URL.revokeObjectURL(objectURL); }, 0);
                            if (typeof options.onload === 'function') options.onload({});
                        }, function (error) { if (typeof options.onerror === 'function') options.onerror(error); });
                    return { abort: function () { if (revoke) clearTimeout(revoke); } };
                };
            }
            if (typeof global.GM_openInTab !== 'function') {
                global.GM_openInTab = function (url, options) {
                    // WKWebView 关掉了 javaScriptCanOpenWindowsAutomatically，
                    // window.open 会返回 null；交给原生用系统浏览器打开。
                    var opened = null;
                    try { opened = global.open(String(url), '_blank'); } catch (ignored) {}
                    if (!opened) {
                        try {
                            window.webkit.messageHandlers[WEB_CHANNEL].postMessage({ type: 'openurl', url: String(url) });
                        } catch (postError) { return { close: function () {} }; }
                        if (options && options.onclose) setTimeout(function () { options.onclose(); }, 0);
                    }
                    return opened || { close: function () {} };
                };
            }
        },

        refreshGlobals: function () {
            var requireFn = this._findRequire();
            this._mirrorSignals(requireFn);

            var socket = this._findSocket();
            if (socket) this._publishSocketAliases(socket);

            // g_utils 只有旧的原生宿主才提供（现在的 CDN bundle 里没有这个模块）。
            // 拿不到就真的拿不到，**不要**给恒等实现顶替：脚本用它编码自定义协议体，
            // 恒等编码 = 静默发错包。只试一次，免得每秒都让它抛一遍。
            if (!global.g_utils && requireFn && !this._gUtilsUnavailable) {
                try {
                    var utils = requireFn('g_utils');
                    if (utils) global.g_utils = utils; else this._gUtilsUnavailable = true;
                } catch (ignoredUtils) {
                    this._gUtilsUnavailable = true;
                }
            }

            if (socket && !global.__ios2GameBridge) {
                global.__ios2GameBridge = {
                    socket: socket,
                    send: function (request) {
                        if (typeof socket.sendAsync === 'function') return socket.sendAsync(request);
                        if (typeof socket.send === 'function') {
                            socket.send(this.encode ? this.encode(request) : JSON.stringify(request));
                            return Promise.resolve({ success: true, message: '命令已发送' });
                        }
                        return Promise.reject(new Error('游戏 WebSocket 不支持发送'));
                    },
                    require: function (name) {
                        if (!requireFn) throw new Error('游戏模块尚未就绪');
                        return requireFn(name);
                    },
                    encode: function (params) {
                        var utils = global.g_utils;
                        if (utils && utils.bon && typeof utils.bon.encode === 'function') {
                            try { return utils.bon.encode(params); } catch (ignored) {}
                        }
                        return params;
                    },
                    getRole: function () { return global.ROLE || null; }
                };
                this._ownedBridge = true;
            }
            return {
                socket: this._findSocket(),
                require: requireFn,
                role: global.ROLE || null,
                bridge: global.__ios2GameBridge || null
            };
        },

        // ROLE 是脚本的「游戏数据」入口（roleInitialized 门闸）。
        // 游戏可能经 ServerData 模块暴露，也可能自己挂 window.ROLE；两条都试。
        _readRole: function () {
            if (global.ROLE) return global.ROLE;
            if (global.ServerData && global.ServerData.ROLE) return global.ServerData.ROLE;
            // 加载器可能还没就绪（bundle 尚未跑完），也可能确实没有 ServerData。
            // 给有限次重试，避免每秒都让游戏加载器抛一次。
            if (!this._findRequire() || (this._roleLookupFailures || 0) >= 10) return null;
            try {
                var serverData = this._findRequire()('ServerData');
                if (serverData && serverData.ROLE) {
                    this._roleLookupFailures = 0;
                    return serverData.ROLE;
                }
            } catch (ignored) {}
            this._roleLookupFailures = (this._roleLookupFailures || 0) + 1;
            return null;
        },

        // 对齐原生 __ios2ApplyRole：补 enchantMap.get，并广播 ROLE 信号。
        _applyRole: function (role) {
            if (!role || typeof role !== 'object') return;
            try {
                role.enchantMap = role.enchantMap || {};
                if (typeof role.enchantMap.get !== 'function') {
                    role.enchantMap.get = function (key) { return this[key]; };
                }
            } catch (ignored) {}
            global.ROLE = role;
        },

        syncRole: function () {
            var role = this._readRole();
            if (role && role.roleId !== undefined) this._applyRole(role);
            if (!this._forwardRoleToNative) return;
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            try {
                var snapshot = this._copyJSONSafe(global.ROLE || {}, 0, []);
                jsb.reflection.callStaticMethod('IOS2Native', 'syncRole:', JSON.stringify(snapshot || {}));
            } catch (error) {
                try { jsb.reflection.callStaticMethod('IOS2Native', 'trace:', 'ROLE sync failed: ' + (error.message || error)); }
                catch (ignored) {}
            }
        },

        stopRoleSync: function () {
            if (this._roleSyncTimer) {
                clearInterval(this._roleSyncTimer);
                this._roleSyncTimer = null;
            }
        },

        startRoleSync: function () {
            this.stopRoleSync();
            this.syncRole();
            var runtime = this;
            this._roleSyncTimer = setInterval(function () { runtime.syncRole(); }, 1000);
        },

        waitForGame: function (timeout, callback) {
            // 这条路径只被旧架构（脚本跑在独立覆盖 WebView，游戏在 Cocos JSB 侧）
            // 使用：入站消息要镜像给覆盖层，ROLE 要推给原生，模块/协议编码由原生代理。
            this._mirrorInbound = true;
            this._forwardRoleToNative = true;
            this.install();
            this._stopEnvironmentPolling();
            var started = Date.now();
            var limit = Math.max(0, Number(timeout) || 15000);
            var poll = function () {
                var environment = runtime.refreshGlobals();
                var ready = !!(environment.socket || environment.bridge) &&
                    !!(environment.require || environment.role);
                if (ready || Date.now() - started >= limit) {
                    runtime.startRoleSync();
                    callback(environment, !ready);
                    return;
                }
                setTimeout(poll, 200);
            };
            poll();
        },

        execute: function (name, source) {
            this.install();
            if (this._executed[name]) return;
            var execute = typeof global.eval === 'function' ? global.eval : eval;
            if (typeof execute !== 'function') throw new Error('当前环境不支持脚本执行');
            execute(String(source) + '\n//# sourceURL=ios2-script/' + name);
            this._executed[name] = true;
        },

        _sendWebViewResponse: function (id, ok, value, error) {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            var message = { id: String(id || ''), ok: !!ok };
            if (ok) {
                try { JSON.stringify(value); message.value = value; }
                catch (ignored) { message.value = null; }
            } else message.error = String(error || '游戏请求失败');
            try {
                jsb.reflection.callStaticMethod('IOS2Native', 'webViewResponse:', JSON.stringify(message));
            } catch (ignoredError) {}
        },

        _sendWebViewEvent: function (event) {
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            try {
                jsb.reflection.callStaticMethod('IOS2Native', 'webViewEvent:', JSON.stringify(event || {}));
            } catch (error) {
                try { jsb.reflection.callStaticMethod('IOS2Native', 'trace:', 'WebView event failed: ' + (error.message || error)); }
                catch (ignored) {}
            }
        },

        handleWebViewRequest: function (message) {
            var request = message;
            if (typeof message === 'string') {
                try { request = JSON.parse(message); } catch (error) { request = null; }
            }
            if (!request || !request.payload) return;
            var id = request.id || (request.payload && request.payload.id) || '';
            var payload = request.payload || {};
            if (request.type === 'bootstrap') {
                var currentRole = global.ROLE || {};
                var role = this._copyJSONSafe(currentRole, 0, []);
                if (!role || typeof role !== 'object') role = {};
                this._sendWebViewResponse(id, true, { role: role, storage: this._copyStorage(), connected: !!this._findSocket() });
                if (this._findSocket()) this._sendWebViewEvent({ type: 'open' });
                return;
            }
            if (request.type === 'storage') {
                var stores = [global.localStorage, global.cc && global.cc.sys && global.cc.sys.localStorage];
                var action = String(payload.action || '');
                var key = payload.key === undefined || payload.key === null ? '' : String(payload.key);
                var value = payload.value === undefined || payload.value === null ? '' : String(payload.value);
                // Keep manager-owned records private and intact. Imported
                // scripts can use arbitrary keys, while the ios2.* namespace
                // contains account/script preferences owned by this app.
                if ((action === 'set' || action === 'remove') && key.indexOf('ios2.') === 0) {
                    this._sendWebViewResponse(id, true, { success: true });
                    return;
                }
                var handled = false;
                for (var storeIndex = 0; storeIndex < stores.length; storeIndex++) {
                    var store = stores[storeIndex];
                    if (!store) continue;
                    try {
                        if (action === 'set' && typeof store.setItem === 'function') {
                            store.setItem(key, value);
                            handled = true;
                        } else if (action === 'remove' && typeof store.removeItem === 'function') {
                            store.removeItem(key);
                            handled = true;
                        } else if (action === 'clear') {
                            if (typeof store.key !== 'function' || typeof store.removeItem !== 'function') continue;
                            var keys = [];
                            var length = Number(store.length) || 0;
                            for (var keyIndex = 0; keyIndex < length; keyIndex++) {
                                var storedKey = store.key(keyIndex);
                                if (storedKey !== null && String(storedKey).indexOf('ios2.') !== 0) keys.push(String(storedKey));
                            }
                            for (var removeIndex = 0; removeIndex < keys.length; removeIndex++) store.removeItem(keys[removeIndex]);
                            handled = true;
                        }
                    } catch (ignored) {}
                    if (handled) break;
                }
                if (!handled) throw new Error('localStorage 不可用');
                this._sendWebViewResponse(id, true, { success: true });
                return;
            }
            if (request.type === 'module') {
                try {
                    var requireFn = this._findRequire();
                    if (!requireFn) throw new Error('游戏模块尚未就绪');
                    var moduleName = String(payload.module || '');
                    var methodName = String(payload.method || '');
                    var module = requireFn(moduleName);
                    var fn = module && module[methodName];
                    if (typeof fn !== 'function') throw new Error('模块方法不存在: ' + moduleName + '.' + methodName);
                    var args = Array.isArray(payload.args) ? payload.args : [];
                    var moduleResult = fn.apply(module, args);
                    if (moduleResult && typeof moduleResult.then === 'function') {
                        moduleResult.then(function (value) {
                            var safe = runtime._copyJSONSafe(value, 0, []);
                            runtime._sendWebViewResponse(id, true, safe === undefined ? null : safe);
                        }, function (error) {
                            runtime._sendWebViewResponse(id, false, null, error && (error.message || error.stack) || error);
                        });
                    } else {
                        var safeResult = this._copyJSONSafe(moduleResult, 0, []);
                        this._sendWebViewResponse(id, true, safeResult === undefined ? null : safeResult);
                    }
                } catch (error) {
                    this._sendWebViewResponse(id, false, null, error && (error.message || error.stack) || error);
                }
                return;
            }
            var socket = this._findSocket();
            if (!socket) {
                this._sendWebViewResponse(id, false, null, '游戏 WebSocket 尚未连接');
                return;
            }
            var body = payload.request || {};
            try {
                if (body.__ios2WebViewPlainBody) {
                    delete body.__ios2WebViewPlainBody;
                    if (body.body && global.g_utils && global.g_utils.bon && typeof global.g_utils.bon.encode === 'function') {
                        body.body = global.g_utils.bon.encode(body.body);
                    } else if (body.params && global.g_utils && global.g_utils.bon && typeof global.g_utils.bon.encode === 'function') {
                        body.body = global.g_utils.bon.encode(body.params);
                        delete body.params;
                    }
                }
                if (request.type === 'send') {
                    if (typeof socket.send !== 'function') throw new Error('游戏 WebSocket 不支持发送');
                    socket.send(payload.data);
                    this._sendWebViewResponse(id, true, { success: true, message: '命令已发送' });
                    return;
                }
                if (typeof socket.sendAsync !== 'function') throw new Error('游戏 WebSocket 不支持 sendAsync');
                var result = socket.sendAsync(body);
                if (result && typeof result.then === 'function') {
                    result.then(function (value) {
                        var output = value;
                        // Keep the complete game response envelope. Some
                        // scripts use cmd/seq/ack while others read _rawData.
                        try {
                            if (value && typeof value === 'object') {
                                var safeValue = runtime._copyJSONSafe(value, 0, []);
                                if (safeValue !== undefined) output = safeValue;
                            }
                        } catch (ignored) {}
                        runtime._sendWebViewResponse(id, true, output);
                    }, function (error) {
                        runtime._sendWebViewResponse(id, false, null, error && (error.message || error.stack) || error);
                    });
                } else this._sendWebViewResponse(id, true, result);
            } catch (error) {
                this._sendWebViewResponse(id, false, null, error && (error.message || error.stack) || error);
            }
        },

        reset: function () {
            this._executed = {};
            this.stopRoleSync();
            this._stopEnvironmentPolling();
            this._mirroredSockets = [];
            this._roleLookupFailures = 0;
            if (this._ownedBridge) {
                try { delete global.__ios2GameBridge; } catch (ignored) { global.__ios2GameBridge = null; }
                this._ownedBridge = false;
            }
            // 只收回本层自己写进去的别名，绝不动游戏或脚本自己设置的。
            for (var index = 0; index < this._ownedSocketAliases.length; index++) {
                var name = this._ownedSocketAliases[index];
                try { delete global[name]; } catch (ignoredAlias) { global[name] = null; }
            }
            this._ownedSocketAliases = [];
        }
    };

    global.__ios2WebViewRequest = function (message) {
        runtime.install();
        runtime.handleWebViewRequest(message);
    };

    global.__ios2ScriptRuntime = runtime;
}(window));
