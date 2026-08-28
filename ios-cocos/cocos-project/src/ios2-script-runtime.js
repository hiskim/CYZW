/* Runtime compatibility layer for imported third-party scripts. */
(function (global) {
    'use strict';

    var runtime = {
        _installed: false,
        _executed: {},
        _ownedSocketAlias: false,
        _ownedBridge: false,
        _roleSyncTimer: null,
        _mirroredSockets: [],

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

        _patchWebSocket: function () {
            try {
                var WebSocket = global.WebSocket;
                var prototype = WebSocket && WebSocket.prototype;
                if (!prototype) return;
                var rememberSocket = function (socket) {
                    if (!global.ws) {
                        global.ws = socket;
                        runtime._ownedSocketAlias = true;
                        runtime.refreshGlobals();
                    }
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

        _ensureSendAsync: function (socket) {
            if (!socket || typeof socket.sendAsync === 'function' || typeof socket.send !== 'function') return socket;
            var originalSend = socket.send;
            socket.sendAsync = function (request) {
                var self = this;
                return new Promise(function (resolve, reject) {
                    var previous = self.onmessage;
                    var finished = false;
                    var timer = setTimeout(function () {
                        if (finished) return;
                        finished = true;
                        self.onmessage = previous;
                        reject(new Error('WebSocket response timeout'));
                    }, 10000);
                    var complete = function (value) {
                        if (finished) return;
                        finished = true;
                        clearTimeout(timer);
                        self.onmessage = previous;
                        resolve(value);
                    };
                    self.onmessage = function (event) {
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
                            if (typeof previous === 'function') previous.call(self, event);
                            return;
                        }
                        if (typeof previous === 'function') previous.call(self, event);
                        complete(parsed);
                    };
                    try {
                        originalSend.call(self, typeof request === 'string' ? request : JSON.stringify(request));
                    } catch (error) {
                        if (!finished) {
                            finished = true;
                            clearTimeout(timer);
                            self.onmessage = previous;
                        }
                        reject(error);
                    }
                });
            };
            return socket;
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
                    return this._mirrorSocket(this._ensureSendAsync(candidate));
                }
            }
            return null;
        },

        _findRequire: function () {
            if (typeof global.__require === 'function') return global.__require;
            if (typeof global.require === 'function') return global.require;
            return null;
        },

        _mirrorSignals: function (requireFn) {
            if (!requireFn) return;
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

        stopRoleSync: function () {
            if (this._roleSyncTimer) {
                clearInterval(this._roleSyncTimer);
                this._roleSyncTimer = null;
            }
        },

        startRoleSync: function () {
            this.stopRoleSync();
            if (!(global.jsb && jsb.reflection && jsb.reflection.callStaticMethod)) return;
            var runtime = this;
            var sync = function () {
                try {
                    var snapshot = runtime._copyJSONSafe(global.ROLE || {}, 0, []);
                    if (!snapshot || typeof snapshot !== 'object') snapshot = {};
                    jsb.reflection.callStaticMethod('IOS2Native', 'syncRole:', JSON.stringify(snapshot));
                } catch (error) {
                    try { jsb.reflection.callStaticMethod('IOS2Native', 'trace:', 'ROLE sync failed: ' + (error.message || error)); }
                    catch (ignored) {}
                }
            };
            sync();
            this._roleSyncTimer = setInterval(sync, 1000);
        },

        install: function () {
            if (this._installed) return;
            this._installed = true;
            // Browser userscript managers provide this alias. Keep the imported
            // source unchanged and expose the same meaning in Cocos JSB.
            if (!global.unsafeWindow) global.unsafeWindow = global;
            this._patchDom();
            this._patchWebSocket();
            this.refreshGlobals();
        },

        refreshGlobals: function () {
            var requireFn = this._findRequire();
            if (requireFn && typeof global.__require !== 'function') global.__require = requireFn;
            this._mirrorSignals(requireFn);

            var socket = this._findSocket();
            if (socket && !global.ws) {
                global.ws = socket;
                this._ownedSocketAlias = true;
            }

            if (!global.g_utils && requireFn) {
                try { global.g_utils = requireFn('g_utils'); } catch (ignored) {}
            }
            if (!global.ROLE && requireFn) {
                try {
                    var serverData = requireFn('ServerData');
                    if (serverData && serverData.ROLE) global.ROLE = serverData.ROLE;
                } catch (ignored) {}
            }
            if (socket && !global.__ios2GameBridge) {
                global.__ios2GameBridge = {
                    socket: socket,
                    send: function (request) {
                        if (typeof socket.sendAsync === 'function') return socket.sendAsync(request);
                        if (typeof socket.send === 'function') {
                            socket.send(JSON.stringify(request));
                            return Promise.resolve({ success: true, message: '命令已发送' });
                        }
                        return Promise.reject(new Error('游戏 WebSocket 不支持发送'));
                    },
                    require: function (name) {
                        if (!requireFn) throw new Error('游戏模块尚未就绪');
                        return requireFn(name);
                    },
                    encode: function (params) {
                        return global.g_utils && global.g_utils.bon && typeof global.g_utils.bon.encode === 'function' ?
                            global.g_utils.bon.encode(params) : params;
                    },
                    getRole: function () { return global.ROLE || null; }
                };
                this._ownedBridge = true;
            }
            return {
                socket: this._findSocket(),
                require: this._findRequire(),
                role: global.ROLE || null,
                bridge: global.__ios2GameBridge || null
            };
        },

        waitForGame: function (timeout, callback) {
            this.install();
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
            this._mirroredSockets = [];
            if (this._ownedBridge) {
                try { delete global.__ios2GameBridge; } catch (ignored) { global.__ios2GameBridge = null; }
                this._ownedBridge = false;
            }
            if (this._ownedSocketAlias) {
                try { delete global.ws; } catch (ignored) { global.ws = null; }
                this._ownedSocketAlias = false;
            }
        }
    };

    global.__ios2WebViewRequest = function (message) {
        runtime.install();
        runtime.handleWebViewRequest(message);
    };

    global.__ios2ScriptRuntime = runtime;
}(window));
