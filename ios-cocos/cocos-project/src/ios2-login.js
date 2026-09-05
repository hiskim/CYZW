/* Native .bin login bridge for the ios2 Cocos JSB runtime. */
(function () {
    'use strict';

    var NativeXHR = window.XMLHttpRequest;
    var nativeReflection = window.jsb && window.jsb.reflection;
    var waiting = [];
    var cachedResponse = null;
    var loginState = 'waiting';

    if (!NativeXHR || !nativeReflection || NativeXHR.__ios2Wrapped) {
        return;
    }

    function emit(target, type, extra) {
        var event = extra || { type: type, target: target };
        var handler = target['on' + type];
        if (typeof handler === 'function') {
            try { handler.call(target, event); } catch (error) { console.error(error); }
        }
        var listeners = target._listeners[type] || [];
        listeners.slice().forEach(function (listener) {
            try { listener.call(target, event); } catch (error) { console.error(error); }
        });
    }

    function decodeBase64(value) {
        var binary = atob(value);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes.buffer;
    }

    function completeFakeRequest(xhr, status, body) {
        if (xhr._timer) {
            clearTimeout(xhr._timer);
            xhr._timer = null;
        }
        xhr._status = status;
        xhr._response = body ? body.slice(0) : new ArrayBuffer(0);
        xhr._responseText = '';
        xhr._readyState = 2;
        emit(xhr, 'readystatechange');
        xhr._readyState = 3;
        emit(xhr, 'readystatechange');
        xhr._readyState = 4;
        emit(xhr, 'readystatechange');
        if (status >= 200 && status < 300) {
            emit(xhr, 'load');
        } else {
            emit(xhr, 'error');
        }
        emit(xhr, 'loadend');
    }

    function flushWaiting(status, body) {
        var requests = waiting.splice(0);
        requests.forEach(function (xhr) {
            completeFakeRequest(xhr, status, body);
        });
    }

    function IOS2XMLHttpRequest() {
        this._native = new NativeXHR();
        this._listeners = Object.create(null);
        this._url = '';
        this._fake = false;
        this._readyState = 0;
        this._status = 0;
        this._response = null;
        this._responseText = '';
        this._responseType = '';
        this._timer = null;
        this._timeout = 120000;
        this.onload = null;
        this.onerror = null;
        this.ontimeout = null;
        this.onabort = null;
        this.onloadend = null;
        this.onreadystatechange = null;
        this.onprogress = null;

        var self = this;
        ['readystatechange', 'load', 'error', 'timeout', 'abort', 'loadend', 'progress'].forEach(function (type) {
            self._native['on' + type] = function (event) {
                if (!self._fake) {
                    emit(self, type, { type: type, target: self, nativeEvent: event });
                }
            };
        });
    }

    IOS2XMLHttpRequest.prototype = Object.create(NativeXHR.prototype);
    IOS2XMLHttpRequest.prototype.constructor = IOS2XMLHttpRequest;

    IOS2XMLHttpRequest.prototype.open = function (method, url) {
        this._url = String(url || '');
        this._fake = /\/login\/authuser(?:\?|$)/.test(this._url);
        if (this._fake) {
            this._readyState = 1;
            this._status = 0;
            emit(this, 'readystatechange');
            return;
        }
        this._native.open.apply(this._native, arguments);
    };

    IOS2XMLHttpRequest.prototype.send = function (body) {
        if (this._fake) {
            waiting.push(this);
            if (loginState === 'ready' && cachedResponse) {
                waiting.splice(waiting.indexOf(this), 1);
                completeFakeRequest(this, 200, cachedResponse);
            } else if (loginState === 'error') {
                waiting.splice(waiting.indexOf(this), 1);
                completeFakeRequest(this, 502, null);
            } else {
                this._timer = setTimeout(function () {
                    var index = waiting.indexOf(this);
                    if (index >= 0) waiting.splice(index, 1);
                    completeFakeRequest(this, 408, null);
                }.bind(this), this.timeout || 120000);
            }
            return;
        }
        this._native.send(body);
    };

    IOS2XMLHttpRequest.prototype.abort = function () {
        if (this._fake) {
            if (this._timer) clearTimeout(this._timer);
            this._readyState = 0;
            emit(this, 'abort');
            emit(this, 'loadend');
            return;
        }
        this._native.abort();
    };

    IOS2XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        if (!this._fake) this._native.setRequestHeader(name, value);
    };

    IOS2XMLHttpRequest.prototype.getAllResponseHeaders = function () {
        if (this._fake) return 'Content-Type: application/octet-stream\r\n';
        return this._native.getAllResponseHeaders();
    };

    IOS2XMLHttpRequest.prototype.getResponseHeader = function (name) {
        if (this._fake && String(name).toLowerCase() === 'content-type') {
            return 'application/octet-stream';
        }
        return this._fake ? null : this._native.getResponseHeader(name);
    };

    IOS2XMLHttpRequest.prototype.overrideMimeType = function (mimeType) {
        if (!this._fake && this._native.overrideMimeType) this._native.overrideMimeType(mimeType);
    };

    IOS2XMLHttpRequest.prototype.addEventListener = function (type, listener) {
        if (typeof listener !== 'function') return;
        (this._listeners[type] || (this._listeners[type] = [])).push(listener);
    };

    IOS2XMLHttpRequest.prototype.removeEventListener = function (type, listener) {
        var listeners = this._listeners[type] || [];
        var index = listeners.indexOf(listener);
        if (index >= 0) listeners.splice(index, 1);
    };

    Object.defineProperties(IOS2XMLHttpRequest.prototype, {
        readyState: { get: function () { return this._fake ? this._readyState : this._native.readyState; } },
        status: { get: function () { return this._fake ? this._status : this._native.status; } },
        statusText: { get: function () { return this._fake ? (this._status === 200 ? 'OK' : '') : this._native.statusText; } },
        response: { get: function () { return this._fake ? this._response : this._native.response; } },
        responseText: { get: function () { return this._fake ? this._responseText : this._native.responseText; } },
        responseType: {
            get: function () { return this._fake ? this._responseType : this._native.responseType; },
            set: function (value) { this._responseType = value || ''; if (!this._fake) this._native.responseType = value; }
        },
        timeout: {
            get: function () { return this._fake ? (this._timeout || 120000) : this._native.timeout; },
            set: function (value) { this._timeout = Number(value) || 0; if (!this._fake) this._native.timeout = value; }
        },
        withCredentials: {
            get: function () { return this._fake ? false : this._native.withCredentials; },
            set: function (value) { if (!this._fake) this._native.withCredentials = value; }
        }
    });

    IOS2XMLHttpRequest.UNSENT = 0;
    IOS2XMLHttpRequest.OPENED = 1;
    IOS2XMLHttpRequest.HEADERS_RECEIVED = 2;
    IOS2XMLHttpRequest.LOADING = 3;
    IOS2XMLHttpRequest.DONE = 4;
    IOS2XMLHttpRequest.__ios2Wrapped = true;
    window.XMLHttpRequest = IOS2XMLHttpRequest;

    window.__ios2BinLoginReady = function (base64Response) {
        try {
            cachedResponse = decodeBase64(base64Response || '');
            loginState = cachedResponse.byteLength > 4 ? 'ready' : 'error';
            if (loginState === 'ready') {
                flushWaiting(200, cachedResponse);
                if (typeof window.__ios2OnBinLoginReady === 'function') {
                    window.__ios2OnBinLoginReady();
                }
                // The authenticated game bundle may set its own 30 FPS default
                // while handling this response. Restore the user's native
                // performance selection after that login work has begun.
                var autoRestore = true;
                try { autoRestore = !window.localStorage || window.localStorage.getItem('ios2.autoRestore') !== '0'; } catch (ignored) {}
                if (autoRestore && typeof window.__ios2SchedulePerformanceRestore === 'function') {
                    window.__ios2SchedulePerformanceRestore('bin login');
                }
            }
            else flushWaiting(502, null);
        } catch (error) {
            loginState = 'error';
            flushWaiting(502, null);
            console.error('[ios2] invalid native login response', error);
        }
    };

    window.__ios2BinLoginFailed = function (message) {
        loginState = 'error';
        console.error('[ios2] native bin login failed:', message || 'unknown error');
        flushWaiting(502, null);
        if (typeof window.__ios2OnBinLoginFailed === 'function') {
            window.__ios2OnBinLoginFailed(message);
        }
    };

    window.__ios2RetryBinLogin = function () {
        loginState = 'waiting';
        nativeReflection.callStaticMethod('IOS2Native', 'selectLoginBin');
    };

    // SwiftUI can request a Cocos launch before this script and the manager
    // are loaded. Native hands the selected filename back now; the manager
    // consumes it only after its account presenter is ready.
    try { nativeReflection.callStaticMethod('IOS2Native', 'consumeNativeCocosLaunch'); }
    catch (error) { console.error('[ios2] native Cocos launch handoff failed', error); }

    // The HSDK login request opens the picker explicitly. Keeping this
    // bridge passive prevents an old cached account from logging in before
    // the user chooses the intended .bin file.
}());
