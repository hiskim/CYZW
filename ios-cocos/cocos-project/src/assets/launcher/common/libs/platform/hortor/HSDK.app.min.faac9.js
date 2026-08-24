!function(e) {
"function" == typeof define && define.amd ? define(e) : e();
}(function() {
"use strict";
window.LIB = {
EventType: {
SendToNative: 0,
ReceiveFromNative: 1,
Init: 2,
Login: 3,
BackBtnTap: 4,
CustomerUnreadMsg: 5
},
ApiType: {
Login: 1
}
};
var e, t = new (function() {
function e() {
this.eventMap = {};
}
return e.prototype.on = function(e, t, n) {
void 0 === n && (n = !1), this.eventMap[e] = this.eventMap[e] || [], this.eventMap[e].push({
callback: t,
isOnce: n
});
}, e.prototype.once = function(e, t) {
this.on(e, t, !0);
}, e.prototype.off = function(e, t) {
if (void 0 === t) this.eventMap[e] = []; else {
var n = this.eventMap[e];
if (n && n.length) for (var o = this.getCallbackIndex(n, t); -1 !== o; ) this.eventMap[e].splice(o, 1), 
o = this.getCallbackIndex(n, t);
}
}, e.prototype.getCallbackIndex = function(e, t) {
var n = -1;
return e.forEach(function(e, o) {
e.callback === t && (n = o);
}), n;
}, e.prototype.emit = function(e) {
for (var t = this, n = [], o = 1; o < arguments.length; o++) n[o - 1] = arguments[o];
var i = this.eventMap[e];
i && i.forEach(function(o) {
var i = o.callback, r = o.isOnce;
"function" == typeof i && (i.apply(void 0, n), r && t.off(e, i));
});
}, e;
}())(), n = !(window && window.egret && window.egret.Capabilities), o = function() {
if (window && window.navigator && window.navigator.userAgent) {
var e = window.navigator.userAgent;
return e.indexOf("mix_micro_end_ios") > -1 || e.indexOf("mix_micro_end_android") > -1;
}
return !1;
}(), i = o ? window.navigator.userAgent.indexOf("mix_micro_end_ios") > -1 : n ? cc.sys.OS ? cc.sys.os === cc.sys.OS.IOS : cc.sys.os === cc.sys.OS_IOS : window && window.egret && window.egret.Capabilities ? "iOS" === egret.Capabilities.os : void 0, r = "sdk";
function a(e) {
var t = e.action, a = e.extra;
if (o) window.android && window.android.webviewSendMsgToAndroid(JSON.stringify({
action: t,
extra: a
})); else if (n) {
var s = i ? "SDKMessager" : "com/hortorgames/gamesdk/SDKBridge", c = i ? "callNative:withMessage:" : "receiveMsgFromHSDK";
i ? jsb.reflection.callStaticMethod(s, c, r, JSON.stringify({
action: t,
extra: a
})) : jsb.reflection.callStaticMethod(s, c, "(Ljava/lang/String;)V", JSON.stringify({
action: t,
extra: a
}));
} else window.egret && egret.ExternalInterface.call(r, JSON.stringify({
action: t,
extra: a
}));
}
function s(e) {
a({
action: "report_log_post",
extra: {
eventName: "hsdk_json_parse_err",
eventType: HSDK.EventType.Track,
logType: HSDK.LogType.TGA,
extra: {
nativeMsg: e
}
}
});
}
t.on(LIB.EventType.SendToNative, function(e) {
a({
action: e.action,
extra: e.payload
});
}), o ? window.androidSendMsgToWebview = function(e) {
try {
JSON.parse(e) && t.emit(LIB.EventType.ReceiveFromNative, e);
} catch (t) {
s(e);
}
} : window.egret && window.egret && window.egret.ExternalInterface && window.egret.ExternalInterface.addCallback && window.egret.ExternalInterface.addCallback(r, function(e) {
try {
JSON.parse(e) && t.emit(LIB.EventType.ReceiveFromNative, e);
} catch (t) {
s(e);
}
});
var c = function(e, t) {
return (c = Object.setPrototypeOf || {
__proto__: []
} instanceof Array && function(e, t) {
e.__proto__ = t;
} || function(e, t) {
for (var n in t) Object.prototype.hasOwnProperty.call(t, n) && (e[n] = t[n]);
})(e, t);
};
function l(e, t) {
if ("function" != typeof t && null !== t) throw new TypeError("Class extends value " + String(t) + " is not a constructor or null");
function n() {
this.constructor = e;
}
c(e, t), e.prototype = null === t ? Object.create(t) : (n.prototype = t.prototype, 
new n());
}
var u = function() {
return (u = Object.assign || function(e) {
for (var t, n = 1, o = arguments.length; n < o; n++) for (var i in t = arguments[n]) Object.prototype.hasOwnProperty.call(t, i) && (e[i] = t[i]);
return e;
}).apply(this, arguments);
};
function d(e, t, n, o) {
return new (n || (n = Promise))(function(i, r) {
function a(e) {
try {
c(o.next(e));
} catch (e) {
r(e);
}
}
function s(e) {
try {
c(o.throw(e));
} catch (e) {
r(e);
}
}
function c(e) {
var t;
e.done ? i(e.value) : (t = e.value, t instanceof n ? t : new n(function(e) {
e(t);
})).then(a, s);
}
c((o = o.apply(e, t || [])).next());
});
}
function p(e, t) {
var n, o, i, r, a = {
label: 0,
sent: function() {
if (1 & i[0]) throw i[1];
return i[1];
},
trys: [],
ops: []
};
return r = {
next: s(0),
throw: s(1),
return: s(2)
}, "function" == typeof Symbol && (r[Symbol.iterator] = function() {
return this;
}), r;
function s(r) {
return function(s) {
return function(r) {
if (n) throw new TypeError("Generator is already executing.");
for (;a; ) try {
if (n = 1, o && (i = 2 & r[0] ? o.return : r[0] ? o.throw || ((i = o.return) && i.call(o), 
0) : o.next) && !(i = i.call(o, r[1])).done) return i;
switch (o = 0, i && (r = [ 2 & r[0], i.value ]), r[0]) {
case 0:
case 1:
i = r;
break;

case 4:
return a.label++, {
value: r[1],
done: !1
};

case 5:
a.label++, o = r[1], r = [ 0 ];
continue;

case 7:
r = a.ops.pop(), a.trys.pop();
continue;

default:
if (!(i = a.trys, (i = i.length > 0 && i[i.length - 1]) || 6 !== r[0] && 2 !== r[0])) {
a = 0;
continue;
}
if (3 === r[0] && (!i || r[1] > i[0] && r[1] < i[3])) {
a.label = r[1];
break;
}
if (6 === r[0] && a.label < i[1]) {
a.label = i[1], i = r;
break;
}
if (i && a.label < i[2]) {
a.label = i[2], a.ops.push(r);
break;
}
i[2] && a.ops.pop(), a.trys.pop();
continue;
}
r = t.call(e, a);
} catch (e) {
r = [ 6, e ], o = 0;
} finally {
n = i = 0;
}
if (5 & r[0]) throw r[1];
return {
value: r[0] ? r[1] : void 0,
done: !0
};
}([ r, s ]);
};
}
}
function f(e, t) {
for (var n = 0, o = t.length, i = e.length; n < o; n++, i++) e[i] = t[n];
return e;
}
function h() {
for (var e = [], t = 0; t < arguments.length; t++) e[t] = arguments[t];
var n = "[HSDK] ";
e.forEach(function(e) {
n += function(e) {
if ("string" == typeof e || "number" == typeof e || "bigint" == typeof e) return e;
try {
return JSON.stringify(e);
} catch (e) {
return "tryJsonStringify fail";
}
}(e) + " ";
}), console.log(n);
}
function g(e) {
for (var t = [], n = 1; n < arguments.length; n++) t[n - 1] = arguments[n];
"function" == typeof e && e.apply(void 0, t);
}
function m() {
for (var e = [], t = 0; t < arguments.length; t++) e[t] = arguments[t];
k.config.isOpenDebug && h.apply(void 0, e);
}
var v = {};
function y(e) {
var t, n = e || {
listener: function() {}
}, o = n.action, i = n.listener, r = n.canAddListener;
v[o] && (null === (t = v[o]) || void 0 === t ? void 0 : t.listenerList) && r ? v[o].listenerList.push(i) : v[o] = {
isListen: !0,
listenerList: [ i ]
};
}
function w(e) {
var n = e.action, o = e.payload, i = void 0 === o ? {} : o;
m("HSDK发送消息给原生", "\n action:", n, "\n payload:", i), t.emit(LIB.EventType.SendToNative, {
action: n,
payload: i
});
}
function I(e) {
w(e), y(e);
}
function S(e) {
var t = e.action, n = e.payload, o = e.apiType;
return new Promise(function(e, i) {
v[t] ? v[t].promiseList.push({
resolve: e,
reject: i,
apiType: o
}) : v[t] = {
isListen: !1,
promiseList: [ {
resolve: e,
reject: i,
apiType: o
} ]
}, w({
action: t,
payload: n
});
});
}
t.on(LIB.EventType.ReceiveFromNative, function(e) {
var t;
try {
var n = JSON.parse(e) || {}, o = n.action, i = n.extra, r = n.meta;
m("HSDK接收到了原生的消息", "\n action:", o, "\n meta:", r, "\n extra:", i);
var a = v[o];
if (null == a ? void 0 : a.isListen) m("持续监听"), null == a || a.listenerList.forEach(function(e) {
g(e, {
extra: i,
meta: r
});
}); else if (null === (t = null == a ? void 0 : a.promiseList) || void 0 === t ? void 0 : t.length) {
var s = a.promiseList.shift();
0 === (null == r ? void 0 : r.errCode) ? s.resolve(i) : s.reject(r);
} else m("err", "promiseList is empty");
} catch (t) {
m("解析JSON失败或游戏代码错误", e);
try {
m("err", JSON.stringify(t));
} catch (e) {
m("err", e);
}
}
});
var T = {
isOpenDebug: !0
}, k = function() {
function e() {}
return Object.defineProperty(e, "config", {
get: function() {
return T;
},
enumerable: !1,
configurable: !0
}), e;
}(), b = LIB.ApiType.Login;
function x() {
return S({
action: "wx-getcode",
apiType: b
});
}
var L = x;
function C() {
return S({
action: "user-visitorlogin",
apiType: b
});
}
var _ = C;
function A(e) {
return S({
action: "cp_share_img_sdcard",
payload: e
});
}
y({
action: "sdk-get-userId",
listener: function(e) {
var n = e.extra;
t.emit(LIB.EventType.Login, n || {});
}
}), y({
action: "sdk-app-back",
listener: function() {
t.emit(LIB.EventType.BackBtnTap);
}
});
var P = "-appshare";
function R() {
return S({
action: "wx-share-get-data"
});
}
var M, O = "function" == typeof atob, E = "function" == typeof Buffer, N = "function" == typeof TextDecoder ? new TextDecoder() : void 0, D = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".split(""), q = (M = {}, 
D.forEach(function(e, t) {
return M[e] = t;
}), M), U = /^(?:[A-Za-z\d+\/]{4})*?(?:[A-Za-z\d+\/]{2}(?:==)?|[A-Za-z\d+\/]{3}=?)?$/, B = String.fromCharCode.bind(String), F = "function" == typeof Uint8Array.from ? Uint8Array.from.bind(Uint8Array) : function(e, t) {
return void 0 === t && (t = function(e) {
return e;
}), new Uint8Array(Array.prototype.slice.call(e, 0).map(t));
}, V = function(e) {
return e.replace(/[^A-Za-z0-9\+\/]/g, "");
}, j = /[\xC0-\xDF][\x80-\xBF]|[\xE0-\xEF][\x80-\xBF]{2}|[\xF0-\xF7][\x80-\xBF]{3}/g, H = function(e) {
switch (e.length) {
case 4:
var t = ((7 & e.charCodeAt(0)) << 18 | (63 & e.charCodeAt(1)) << 12 | (63 & e.charCodeAt(2)) << 6 | 63 & e.charCodeAt(3)) - 65536;
return B(55296 + (t >>> 10)) + B(56320 + (1023 & t));

case 3:
return B((15 & e.charCodeAt(0)) << 12 | (63 & e.charCodeAt(1)) << 6 | 63 & e.charCodeAt(2));

default:
return B((31 & e.charCodeAt(0)) << 6 | 63 & e.charCodeAt(1));
}
}, J = O ? function(e) {
return atob(V(e));
} : E ? function(e) {
return Buffer.from(e, "base64").toString("binary");
} : function(e) {
if (e = e.replace(/\s+/g, ""), !U.test(e)) throw new TypeError("malformed base64.");
e += "==".slice(2 - (3 & e.length));
for (var t, n, o, i = "", r = 0; r < e.length; ) t = q[e.charAt(r++)] << 18 | q[e.charAt(r++)] << 12 | (n = q[e.charAt(r++)]) << 6 | (o = q[e.charAt(r++)]), 
i += 64 === n ? B(t >> 16 & 255) : 64 === o ? B(t >> 16 & 255, t >> 8 & 255) : B(t >> 16 & 255, t >> 8 & 255, 255 & t);
return i;
}, K = E ? function(e) {
return F(Buffer.from(e, "base64"));
} : function(e) {
return F(J(e), function(e) {
return e.charCodeAt(0);
});
}, G = E ? function(e) {
return Buffer.from(e, "base64").toString("utf8");
} : N ? function(e) {
return N.decode(K(e));
} : function(e) {
return J(e).replace(j, H);
}, Q = function(e) {
return G(function(e) {
return V(e.replace(/[-_]/g, function(e) {
return "-" == e ? "+" : "/";
}));
}(e));
}, W = function() {
function e(e) {
void 0 === e && (e = {}), this.onStartListener = function() {}, this.onStopListener = function() {}, 
this.onMsgListener = function() {}, this.onErrListener = function() {}, this.isStoped = !1, 
this.opt = e;
var t = this;
y({
action: "start_recorder",
listener: function(e) {
var n = e.extra || {}, o = n.resultText, i = n.end, r = n.code;
if (1 === i && (t.isStoped = !0, t.onStopListener()), 1e3 === r) {
var a = {
errCode: r,
errMsg: o
};
t.onErrListener(a);
} else t.isStoped || t.onMsgListener(o);
}
}), y({
action: "stop_recorder",
listener: function() {
t.onStopListener();
}
});
}
return e.prototype.onStart = function(e) {
this.onStartListener = e;
}, e.prototype.onStop = function(e) {
this.onStopListener = e;
}, e.prototype.onMessage = function(e) {
this.onMsgListener = e;
}, e.prototype.onError = function(e) {
this.onErrListener = e;
}, e.prototype.start = function() {
var e = {};
"number" == typeof this.opt.duration && (e.recTime = this.opt.duration / 1e3), w({
action: "start_recorder",
payload: e
}), this.isStoped = !1;
}, e.prototype.stop = function() {
w({
action: "stop_recorder"
});
}, e.prototype.setOption = function(e) {
void 0 === e && (e = {}), this.opt = Object.assign(this.opt, e);
}, e;
}(), X = null, z = "__APM_TEMP_LOGS", Y = function() {
function e(e, t) {
this.app = e, this._temp = null, this._max = t.MaxTempFailLogLength || 0, this.enable = t.EnabledTempFailLog;
}
return e.prototype.setStorage = function(e) {
try {
this._temp = e, this.app.setStorage(z, e);
} catch (e) {
console.log("[APM] set storage err: ", e);
}
}, e.prototype.getStorage = function() {
var e = this._temp;
if (e) return e;
try {
e = this.app.getStorage(z), this._temp = e;
} catch (t) {
e = "", console.log("[APM] get storage err: ", t);
}
return e;
}, e.prototype.limitLens = function(e, t) {
var n = e, o = e.length - t;
return t > 0 && o > 0 && (n = e.slice(o)), n;
}, e.prototype.setTemp = function(e) {
if (this.enable) {
var t = this._temp || [];
t.push(e), this._temp = this.limitLens(t, this._max), console.log("[APM] storage fail log: ", this._temp), 
this.setStorage(this._temp);
}
}, e.prototype.mergeNum = function(e, t) {
var n = e || t;
if (n) {
for (var o in t = t || {}, e = e || {}, n) t[o] = t[o] || 0, t[o] += e[o] || 0;
return t;
}
}, e.prototype.mergeTemp = function(e, t) {
var n = t || {}, o = n.logs, i = n.sockets, r = n.times, a = e || {}, s = a.logs, c = a.sockets, l = a.times, u = {};
u.logs = this.limitLens((s || []).concat(o || []), this._max), u.sockets = this.mergeNum(i, c);
var d = r || l;
if (d) for (var p in u.times = {}, d) u.times[p] = this.mergeNum((r || {})[p], (l || {})[p]);
return u;
}, e.prototype.getTemp = function(e) {
var t = this;
if (!this.enable) return e;
var n = this.getStorage(), o = Object.assign({}, e || {});
return n && n.length && (n.forEach(function(e) {
o = t.mergeTemp(e, o);
}), console.log("[APM] merge storage log: ", o), this.clear()), o;
}, e.prototype.checkTemp = function() {
return this.enable && this.getStorage();
}, e.prototype.clear = function() {
this.setStorage("");
}, e;
}(), Z = function() {
function e(e, t) {
this.clientInfo = null, this.app = e, this.config = t, this.logTemper = new Y(this.app, t);
}
return e.prototype.setUserInfo = function(e) {
this.config.userInfo = Object.assign(this.config.userInfo || {}, e);
}, e.prototype.setSysInfo = function(e) {
var t = this.app.sysInfo;
this.sysInfo = Object.assign({}, t, e), console.log("[APM] setSysInfo:", JSON.stringify(this.sysInfo));
}, e.prototype.getClientInfo = function() {
var e = this.sysInfo;
return e.netType = this.app.getConnectionType() || e.netType, e;
}, e.prototype.report = function(e) {
void 0 === e && (e = {});
var t = e.logs, n = e.times, o = e.sockets;
if (this.logTemper.checkTemp() || e.logs && e.logs.length || e.times || e.sockets) {
var i = [];
t.length > 0 && (i = t.map(function(e) {
return e.toJSON();
}));
var r = this.logTemper.getTemp({
logs: i,
times: n,
sockets: o
});
if (!r.logs || 0 != r.logs.length) {
var a = this.config, s = {
game: {
gameId: a.gameId,
version: a.gameVersion,
env: a.env
},
client: this.getClientInfo(),
user: a.userInfo,
logs: r.logs
};
console.log("[APM]", JSON.stringify(s)), this.post(s, function() {});
}
}
}, e.prototype.getReportUrl = function() {
var e = this.config, t = e.apmPostArea, n = e.reportUrlMap, o = e.Debug, i = "https://".concat(n[t], "platform-stat").concat(o ? "-test" : "", ".hortorgames.com/wxlog/api/v1/apmlog");
return 0 === t && (i = "https://platform-apm".concat(o ? "-test" : "", ".hortorgames.com/apm/api/v1/collect")), 
console.warn("getReportUrl", i), i;
}, e.prototype.post = function(e, t) {
var n = new XMLHttpRequest();
n.timeout = 5e3, n.open("POST", this.getReportUrl(), !0), n.setRequestHeader("Content-Type", "application/json"), 
n.onreadystatechange = function() {
if (4 === n.readyState) {
var e = n.status, o = "";
try {
o = n.responseText;
} catch (e) {
o = "not text";
}
if (console.log("[APM] report end", e, o), 200 == e) try {
var i = JSON.parse(o);
if (i.meta && i.meta.errCode) return void (t && t(null, i.meta));
t && t(i.data);
} catch (e) {
t && t(null, e);
} else t && t(null, {
errCode: e,
errMsg: o
});
}
}, n.send(JSON.stringify(e));
}, e;
}(), $ = [ "wxmini", "wxmini-log", "platform", "wxmini-test", "platform-test", "wxmini-dev", "platform-dev" ], ee = "requestTimes", te = function() {
function e(e) {
this.collector = e, this.reset();
}
return e.prototype.getPlatformByUrl = function(e) {
var t = e.split("//"), n = t.length > 1 && t[1] ? t[1].split(".") : [], o = n.length ? n[0] : "";
return $.indexOf(o) > -1 ? "platformSource" : "gameSource";
}, e.prototype.add = function(e, t) {
if (e && "string" == typeof e) {
this.hadData = !0;
var n = this.getPlatformByUrl(e);
this.requestInfo[n][t] += 1;
}
}, e.prototype.reset = function() {
this.hadData = !1, this.requestInfo = {
platformSource: {
requestTimes: 0,
downloadTimes: 0
},
gameSource: {
requestTimes: 0,
downloadTimes: 0
}
};
}, e.prototype.getInfo = function() {
return this.hadData ? this.requestInfo : void 0;
}, e;
}(), ne = function() {
function e(e) {
this.collector = e, this.reset();
}
return e.prototype.add = function(e) {
e && (this.hasSocketData = !0, this.socketInfo[e] += 1);
}, e.prototype.reset = function() {
this.hasSocketData = !1, this.socketInfo = {
connectTimes: 0,
disconnectTimes: 0
};
}, e.prototype.getInfo = function() {
return this.hasSocketData ? this.socketInfo : void 0;
}, e;
}(), oe = {
Debug: !1,
ReportDelay: 6e4,
ErrorReportDelay: 2e3,
ClearRepeatLog: !0,
EnabledAppOnErr: !0,
EnabledResErr: !0,
EnabledResPerf: !0,
EnabledSocket: !1,
EnabledSocketTimes: !1,
EnabledMemoryWarning: !1,
EnabledTempFailLog: !1,
MaxTempFailLogLength: 100,
Filters: [],
reportUrlMap: [ "", "tp-", "asia-", "us-" ]
}, ie = {
Filters: [ /\/v1\/statlog$/, /\/v1\/log$/, /\/v1\/log\/multi$/, /apm\/api\/v1\/collect$/ ]
}, re = function() {
function e(e, t) {
this.logs = [], this.started = !1, this.app = e, this.config = t, this.reporter = new Z(this.app, t), 
this.timeser = new te(null), this.socketTimeser = new ne(null);
}
return e.prototype.clearReporter = function(e) {
return e && clearTimeout(e), null;
}, e.prototype.finalReport = function() {
var e = this.logs, t = this.timeser.getInfo(), n = this.socketTimeser.getInfo();
this.reporter.report({
logs: e,
times: t,
sockets: n
}, function() {}), this.logs = [], this.timeser.reset(), this.socketTimeser.reset(), 
this.errorReporterTimer = this.clearReporter(this.errorReporterTimer), this.fixedReporter = this.clearReporter(this.fixedReporter), 
this.fixedReport();
}, e.prototype.fixedReport = function() {
this.fixedReporter = setTimeout(this.finalReport.bind(this), this.config.ReportDelay);
}, e.prototype.startFixedReport = function() {
this.started || (this.started = !0, this.fixedReport());
}, e.prototype.tryReport = function(e) {
var t = this;
this.checkValid(e) && (this.add(e), this.errorReporterTimer || (this.errorReporterTimer = setTimeout(function() {
t.finalReport();
}, this.config.ErrorReportDelay)));
}, e.prototype.collect = function(e) {
this.checkValid(e) && this.add(e);
}, e.prototype.checkValid = function(e) {
if (!e) return !1;
var t = this.reporter.getReportUrl();
return !(e.resURI && e.resURI.indexOf(t) > -1 || e.resURI && (this.filters || (this.filters = ie.Filters || [], 
this.filters = this.filters.concat(this.config.Filters)), this.filters.length && this.filters.some(function(t) {
return t && t.test && t.test(e.resURI);
})));
}, e.prototype.isRepeat = function(e, t) {
return void 0 === e && (e = {}), void 0 === t && (t = {}), !(!e.id || e.id !== t.id) || !!this.config.ClearRepeatLog && [ "resURI", "logType", "extra" ].every(function(n) {
return JSON.stringify(e[n]) == JSON.stringify(t[n]);
});
}, e.prototype.add = function(e) {
var t = this;
this.logs.some(function(n, o) {
if (t.isRepeat(e, n)) return (!e.timestamp || e.timestamp > n.timestamp) && (t.logs[o] = e), 
!0;
}) || (this.logs.push(e), this.startFixedReport());
}, e.prototype.addTimes = function(e, t) {
this.checkValid({
resURI: e
}) && (this.timeser.add(e, t), this.startFixedReport());
}, e.prototype.addSocketTimes = function(e) {
this.socketTimeser.add(e), this.startFixedReport();
}, e;
}(), ae = 1, se = [ "comb-platform", "comb-platform-test", "comb-platform-dev" ], ce = "res-req", le = function() {
function e(e, t) {
void 0 === t && (t = {}), this.id = ae++, this.logType = e, this.extra = {}, this.collected = !1, 
this.collector = t, this.initTimes();
}
return e.prototype.setType = function(e) {
return this.logType = e, this;
}, e.prototype.addExtra = function(e) {
return e.url && (this.resURI = e.url), e.errMsg && !e.msg && (e.msg = e.errMsg), 
this.extra = Object.assign(this.extra, e), this;
}, e.prototype.start = function() {
return this.startTime = new Date().getTime(), this;
}, e.prototype.updateTimes = function(e) {
return this.requestInfo = e.requestInfo, this.socketInfo = e.socketInfo, this;
}, e.prototype.initTimes = function(e) {
e && "all" != e ? "requestInfo" == e ? this.initRequestInfo() : this.initSocketInfo() : (this.initRequestInfo(), 
this.initSocketInfo());
}, e.prototype.initRequestInfo = function() {
this.requestInfo = {
platformSource: {
requestTimes: 0,
downloadTimes: 0
},
gameSource: {
requestTimes: 0,
downloadTimes: 0
}
};
}, e.prototype.initSocketInfo = function() {
this.socketInfo = {
connectTimes: 0,
disconnectTimes: 0
};
}, e.prototype.addRequestTimes = function(e, t) {
var n = this.getPlatformByUrl(e);
this.requestInfo[n][t] += 1;
}, e.prototype.addSocketTimes = function(e) {
this.socketInfo[e] += 1;
}, e.prototype.end = function() {
return this.timestamp = new Date().getTime() - this.startTime, this.timestamp = this.timestamp < 0 ? 0 : this.timestamp, 
this.collect(), this;
}, e.prototype.collect = function() {
return this.collected || "function" != typeof this.collector.collect || (this.collected = !0, 
this.collector.collect(this)), this;
}, e.prototype.tryReport = function() {
return this.collected || "function" != typeof this.collector.tryReport || (this.collected = !0, 
this.collector.tryReport(this)), this;
}, e.prototype.toJSON = function() {
return {
res: this.resURI,
type: this.logType,
ts: this.timestamp,
ext: this.extra,
requestInfo: this.requestInfo,
socketInfo: this.socketInfo
};
}, e.prototype.getPlatformByUrl = function(e) {
var t = [];
"string" == typeof e && (t = e.split("//"));
var n = [];
"string" == typeof t[1] && (n = t[1].split("."));
var o = n.length ? n[0] : "";
return se.indexOf(o) > -1 ? "platformSource" : "gameSource";
}, e;
}(), ue = function() {
function e(e) {
this.win = e, this._storage = {}, this.sysInfo = this.getSysInfo();
}
return e.prototype.getWindow = function() {
return this.win;
}, e.prototype.getSysInfo = function() {
var e = {}, t = this.win || {}, n = t.navigator ? t.navigator.userAgent : "";
if (!n) return e;
var o = !!n.match(/\(i[^;]+;( U;)? CPU.+Mac OS X/), i = n.match(/\((.+?)\)/g);
n.replace(/\((.+?)\)/g, "").replace(/\s+/g, " ").split(" ").forEach(function(t) {
var n = t.split("/");
e[n[0]] = n[1] || !0;
});
var r = i[0].replace(/\(|\)/g, "").replace(/;\s+/g, ";").split(";");
if (o) e.platform = r[0], e.system = r[1].replace(" like Mac OS X", "").replace("CPU ", ""), 
e.brand = r[0]; else {
e.platform = r[1], e.system = r[1];
var a = (r[2] || "").split(" ");
e.brand = a[0], e.model = (a[1] || "").replace("Build/", "");
}
return {
version: e.Version,
system: e.system,
platform: e.platform,
sdk: e.SDKVersion,
model: e.model,
brand: e.brand,
netType: e.NetType || ""
};
}, e.prototype.getLocationOrigin = function() {
return this.win.location.origin;
}, e.prototype.getPerformanceTimeing = function() {
return this.win.performance && this.win.performance.timing ? this.win.performance.timing : null;
}, e.prototype.getPerformanceEntries = function() {
return this.win.performance && this.win.performance.getEntries ? this.win.performance.getEntries() : {};
}, e.prototype.getConnectionType = function() {
if (!this.win.navigator || !this.win.connection) return "unknow";
var e = this.win.navigator.connection || {};
return e.type || e.effectiveType;
}, e.prototype.setStorage = function(e, t) {
if (e && (this._storage[e] = t, this.win.localStorage)) try {
var n = JSON.stringify(t);
this.win.localStorage.setItem(e, n);
} catch (e) {}
}, e.prototype.getStorage = function(e) {
var t = this._storage[e];
if (t) return t;
if (!e || !this.win.localStorage) return "";
var n = this.win.localStorage.getItem(e) || "";
try {
t = JSON.parse(n);
} catch (e) {
t = n;
}
return t;
}, e.prototype.addEventListener = function(e, t, n) {
this.win.addEventListener && this.win.addEventListener(e, t, n);
}, Object.defineProperty(e.prototype, "XMLHttpRequest", {
get: function() {
return this.win.XMLHttpRequest ? this.win.XMLHttpRequest : {};
},
set: function(e) {
this.win.XMLHttpRequest = e;
},
enumerable: !1,
configurable: !0
}), Object.defineProperty(e.prototype, "navigator", {
get: function() {
return this.win.navigator ? this.win.navigator : {};
},
enumerable: !1,
configurable: !0
}), Object.defineProperty(e.prototype, "MutationObserver", {
get: function() {
return this.win.MutationObserver || this.win.WebKitMutationObserver || this.win.MozMutationObserver || {};
},
enumerable: !1,
configurable: !0
}), e;
}(), de = function() {
function e(e) {
var t = e.app, n = e.config, o = e.collector;
this.app = t, this.config = n, this.collector = o;
}
return e.prototype.handle = function() {}, e.prototype.isFun = function(e) {
return !(!e || "function" != typeof e);
}, e.prototype.tracker = function(e, t) {
return void 0 === t && (t = {}), new le(e, this.collector).addExtra(t);
}, e;
}(), pe = function(e) {
function t(t) {
return e.call(this, t) || this;
}
return l(t, e), t.prototype.handleStackStr = function(e) {
return e.split("\n").map(function(e) {
for (var t = 0, n = 0; n < e.length; n++) if ("]" === e[n]) {
t = n;
break;
}
return e.substr(t + 1);
});
}, t.prototype.handle = function() {
var e = this;
if (this.config.EnabledAppOnErr) {
var t, n = this.onError.bind(this);
Object.defineProperty(this.app.getWindow(), "onerror", {
get: function() {
return function() {
for (var e = [], o = 0; o < arguments.length; o++) e[o] = arguments[o];
n.apply(void 0, e), "function" == typeof t && t.apply(void 0, e);
};
},
set: function(e) {
t = e;
}
});
var o = {};
window.__errorHandler = function(t, n, i, r) {
var a = e.handleStackStr(r);
void 0 === o[i] && (o[i] = 1, e.onError(i, t, n, 0, {
stack: a
}));
}, jsb.onError(function(t, n, o) {
if ("unhandledRejectedPromise" === n) {
var i = e.handleStackStr(o).filter(Boolean);
if (i.length < 2) return;
e.onError(n, i[1], t, 0, {
stack: i
});
}
});
}
}, t.prototype.onError = function(e, t, n, o, i) {
console.log("[APM] onerror: ", e, t, n, o, JSON.stringify(i));
var r = i ? i.stack : "";
this.tracker("unc-err").addExtra({
url: t,
line: n,
column: o,
msg: e,
stack: r
}).tryReport();
}, t;
}(de), fe = function(e) {
function t(t) {
return e.call(this, t) || this;
}
return l(t, e), t.prototype.handle = function() {
this.app.XMLHttpRequest = this.wrapXMLHttpRequest(this.app.XMLHttpRequest);
}, t.prototype.wrapXMLHttpRequest = function(e) {
var t = this;
return function() {
var n = new e(), o = t.app.getWindow(), i = t.tracker(ce, {
url: o && o.location && o.location.href
}), r = "", a = function(e) {
console.log("[APM] request err", JSON.stringify(e)), t.config.EnabledResErr && i.startTime && (i.addRequestTimes(r, ee), 
i.setType("res-err").addExtra(e).end());
};
return n.origOpen = n.open, n.open = function(e, t, o, a, s) {
void 0 === o && (o = !0), function(e, t) {
i.addExtra({
url: t,
method: e
}).start(), r = t;
}(e, t), n.origOpen(e, t, o, a, s);
}, n.addEventListener("error", function(e) {
a({
err: e,
url: r
});
}), n.addEventListener("timeout", function(e) {
a({
err: e,
url: r
});
}), n.addEventListener("readystatechange", function() {
if (4 == n.readyState) {
var e = n.getResponseHeader("Content-Length") || 0, o = n.status, s = "";
try {
s = n.responseText;
} catch (e) {
s = "not text";
}
200 == o ? (c = {
status: o,
size: e,
url: r
}, t.config.EnabledResPerf && i.startTime && (i.addRequestTimes(r, ee), i.setType(ce).addExtra(c).end())) : 0 != o && a({
status: o,
size: e,
err: s,
url: r
});
}
var c;
}), n;
};
}, t;
}(de), he = function() {
function e(e, t) {
var n = new ue(e);
this.config = t, this.collector = new re(n, t);
var o = {
app: n,
config: t,
collector: this.collector
};
this.handlers = [ new pe(o), new fe(o) ];
}
return e.prototype.track = function() {
return this.handlers.forEach(function(e) {
e.handle();
}), this;
}, e.prototype.tracker = function(e, t) {
return void 0 === t && (t = {}), new le(e, this.collector).addExtra(t);
}, e.prototype.setUserInfo = function(e) {
this.collector && this.collector.reporter.setUserInfo(e);
}, e.prototype.setSysInfo = function(e) {
this.collector && this.collector.reporter.setSysInfo(e);
}, e;
}(), ge = {
version: "0.1.2-2021-1-11",
date: 1610368558987,
mode: "dev"
}, me = new (function() {
function e() {}
return e.prototype.init = function(e) {
void 0 === e && (e = {}), e.Debug = !e.env || "Prod" !== e.env || e.Debug, e.apmPostArea = e.apmPostArea || 0, 
console.log("[APM] config", typeof window), this.appTracker = new he(window, Object.assign({}, oe, ge, e)).track();
}, e.prototype.notify = function(e, t) {
return void 0 === t && (t = {}), this.appTracker ? this.appTracker.tracker("game-notice", Object.assign({
msg: e
}, t)).collect() : {
errMsg: "please init apm first"
};
}, e.prototype.notifyError = function(e, t) {
return this.notify(e, t);
}, e.prototype.newTracker = function(e, t) {
return this.appTracker ? this.appTracker.tracker("game-track", Object.assign({
msg: e
}, t)) : {
errMsg: "please init apm first"
};
}, e.prototype.setUserInfo = function(e) {
this.appTracker && this.appTracker.setUserInfo(e);
}, e.prototype.setSysInfo = function(e) {
this.appTracker && this.appTracker.setSysInfo(e);
}, e;
}())(), ve = {
gameId: "",
gameVersion: "",
env: "",
apmPostArea: 0
}, ye = {}, we = {
userId: ""
};
function Ie(e) {
try {
var t = (n = arguments, o = Array.prototype.slice, i = [ void 0 ], void 0 === (r = n) && (r = null), 
o.apply(r, i));
t.unshift("[apm]: "), console.log.apply(this, t);
} catch (e) {
console.log("print err", e);
}
var n, o, i, r;
}
var Se = [], Te = !1;
function ke(e) {
Se.push(e), Te || (Te = !0, function() {
try {
var e = "-test";
"Prod" !== ve.env && 1 !== ve.env && "Production" !== ve.env || (e = "");
var t = "https://".concat(oe.reportUrlMap[ve.apmPostArea], "platform-stat").concat(e, ".hortorgames.com/wxlog/api/v1/apmlog");
0 === ve.apmPostArea && (t = "https://platform-apm".concat(e, ".hortorgames.com/apm/api/v1/collect")), 
console.log("apm url", t);
var n = {
game: {
gameId: ve.gameId,
version: ve.gameVersion,
env: ve.env
},
client: ye,
user: {
userId: we.userId
},
logs: Se
}, o = new XMLHttpRequest();
o.timeout = 5e3, o.open("POST", t, !0), o.setRequestHeader("Content-Type", "application/json"), 
o.send(JSON.stringify(n)), Se = [];
} catch (e) {
Ie("postLog err", e);
}
}(), setTimeout(function() {
Te = !1;
}, 2e3));
}
var be = {
platformSource: {
requestTimes: 0,
downloadTimes: 0
},
gameSource: {
requestTimes: 0,
downloadTimes: 0
}
};
try {
if (cc && cc.assetManager && cc.assetManager.downloader && cc.assetManager.downloader.download) {
var xe = cc.assetManager.downloader.download;
cc.assetManager.downloader.download = function(e, t, n, o, i) {
var r = Date.now();
xe.call(cc.assetManager.downloader, e, t, n, o, function(e, n) {
var o = Date.now() - r, a = "", s = "";
if (e ? (a = "down-err", Ie("下载错误", e), s = e.toString()) : a = "down-req", t.startsWith("https")) {
var c = JSON.parse(JSON.stringify(be));
c.gameSource.downloadTimes = 1, ke({
type: a,
requestInfo: c,
ext: {
url: t,
msg: s
},
ts: o
});
}
i(e, n);
});
};
}
} catch (e) {
Ie("err", e);
}
function Le(e) {
var t;
void 0 === (null == e ? void 0 : e.eventType) && (e.eventType = HSDK.EventType.Track), 
void 0 === (null == e ? void 0 : e.logType) && (e.logType = HSDK.LogType.TGA), (null == e ? void 0 : e.customData) && (e.extra = e.customData), 
(null === (t = null == e ? void 0 : e.eventName) || void 0 === t ? void 0 : t.toLowerCase().includes("sdk")) && function() {
for (var e = [], t = 0; t < arguments.length; t++) e[t] = arguments[t];
m.apply(void 0, f([ "[!!!warn!!!]" ], e));
}('请不要在eventName中包含"sdk"'), w({
action: "report_log_post",
payload: e
});
}
t.on(LIB.EventType.Init, function(e) {
var t = e.config, n = e.sysInfo;
me.init(t), me.setSysInfo(n), Object.keys(t).forEach(function(e) {
ve[e] = t[e];
}), Object.keys(n).forEach(function(e) {
ye[e] = n[e];
});
}), t.on(LIB.EventType.Login, function(e) {
var t = (e || {}).userId;
me.setUserInfo({
userId: t
}), we.userId = t;
});
var Ce = {};
function _e(e) {
if (null == e ? void 0 : e.id) {
var t = e.id;
e.placementId = t;
var n = Ce[t];
n ? "loaded" === n.status ? (e.style ? e.extra = Object.assign({
left: 0,
top: 0,
width: 320,
height: 50
}, e.style) : e.extra = {
left: 0,
top: 0,
width: 320,
height: 50
}, n.showOption = e, I({
action: "show_ad",
payload: e,
listener: function(t) {
var n = t.extra || {}, o = n.callbackName, r = n.param, a = n.error, s = n.errCode, c = n.placementId, l = Ce[c];
if (l && "loaded" === l.status) {
e = l.showOption, a && !i && (r = Q(r));
var u = e;
"onReward" === o || "yh_adReward" === o ? (g(null == u ? void 0 : u.onReward, r), 
l.hasReward = !0) : "onRewardedVideoAdPlayFailed" === o || "yh_adPlayError" === o ? g(null == u ? void 0 : u.onPlayFail, {
errCode: s,
errMsg: null == a ? void 0 : a.errMsg
}) : "onRewardedVideoAdClosed" === o || "yh_adClose" === o ? (l.hasReward ? g(null == u ? void 0 : u.onFinishClose, r) : g(null == u ? void 0 : u.onQuitClose, r), 
g(null == e ? void 0 : e.onClose, r)) : "onRewardedVideoAdPlayStart" === o || "yh_adStart" === o ? g(null == u ? void 0 : u.onPlayStart, r) : "onRewardedVideoAdPlayEnd" === o || "yh_adFinish" === o ? g(null == u ? void 0 : u.onPlayEnd, r) : "onRewardedVideoAdPlayClicked" === o || "yh_click" === o ? g(null == e ? void 0 : e.onClick, r) : "onRewardDeepLinkOrJump" === o && g(null == e ? void 0 : e.onDeepLinkOrJump, r);
var d = e;
"onBannerShow" === o ? g(null == d ? void 0 : d.onShowSuccess, r) : "onBannerClose" === o ? g(null == e ? void 0 : e.onClose, r) : "onBannerAutoRefreshed" === o ? g(null == d ? void 0 : d.onRefreshSuccess, r) : "onBannerAutoRefreshFail" === o ? g(null == d ? void 0 : d.onRefreshFail, {
errCode: s,
error: null == a ? void 0 : a.errMsg
}) : "onBannerClicked" === o ? g(null == e ? void 0 : e.onClick, r) : "onBannerDeepLinkOrJump" === o && g(null == e ? void 0 : e.onDeepLinkOrJump, r);
var p = e;
"onInterstitialAdShow" === o ? g(null == p ? void 0 : p.onShowSuccess, r) : "onInterstitialAdClose" === o ? g(null == e ? void 0 : e.onClose, r) : "onInterstitialAdVideoStart" === o ? g(null == p ? void 0 : p.onPlayStart, r) : "onInterstitialAdVideoEnd" === o ? g(null == p ? void 0 : p.onPlayEnd, r) : "onInterstitialAdVideoError" === o ? g(null == p ? void 0 : p.onPlayFail, r) : "onInterstitialAdClicked" === o ? g(null == e ? void 0 : e.onClick, r) : "onInterstitialDeepLinkOrJump" === o && g(null == e ? void 0 : e.onDeepLinkOrJump, r);
var f = e;
"onVideoShow" === o ? g(null == f ? void 0 : f.onShowSuccess, r) : "onVideoShowSkip" === o ? g(null == f ? void 0 : f.onSkip, r) : "onVideoShowFail" === o ? g(null == f ? void 0 : f.onShowFail, r) : "onVideoReward" === o ? g(null == f ? void 0 : f.onReward, r) : "onVideoClose" === o ? g(null == e ? void 0 : e.onClose, r) : "onVideoClick" === o && g(null == e ? void 0 : e.onClick, r);
}
}
})) : "loading" === n.status && (n.isImmediateShow = !0, n.showOption = e) : g(null == e ? void 0 : e.onShowFail, {
errMsg: "makesure preload before show"
});
}
}
var Ae = 1, Pe = {}, Re = "get-check-switchs", Me = 1;
y({
action: Re,
listener: function(e) {
var t = e.extra, n = e.meta;
if ((null == t ? void 0 : t.sequence) && Pe[t.sequence]) {
var o = Pe[t.sequence];
if (o) if (0 === (null == n ? void 0 : n.errCode)) {
var i = {};
null == t || t.data.forEach(function(e, t) {
if (o.switchIdList) {
var n = o.switchIdList[t];
i[n] = e;
}
}), o.hasHandled || (o.resolve(i), o.hasHandled = !0);
} else o.hasHandled || (o.reject(n), o.hasHandled = !0);
} else {
var r = Pe[Me];
if (Me++, r) if (0 === (null == n ? void 0 : n.errCode)) {
var a = {};
null == t || t.data.forEach(function(e, t) {
if (r.switchIdList) {
var n = r.switchIdList[t];
a[n] = e;
}
}), r.hasHandled || (r.resolve(a), r.hasHandled = !0);
} else r.hasHandled || (r.reject(n), r.hasHandled = !0);
}
}
});
var Oe, Ee = {};
function Ne(e) {
return new Promise(function(t, n) {
try {
var o = new XMLHttpRequest(), i = e.method ? e.method.toUpperCase() : "GET", r = e.url, a = e.params;
if ("GET" === i && a) {
var s = [];
for (var c in a) s.push(encodeURIComponent(c) + "=" + encodeURIComponent(a[c]));
r += (-1 === r.indexOf("?") ? "?" : "&") + s.join("&");
}
o.open(i, r), o.onload = function() {
if (200 === o.status) {
var e = JSON.parse(o.responseText);
e && e.meta && 0 === e.meta.errCode ? t(e.data ? e.data : e.meta) : n(e.meta);
} else n(o.statusText);
}, o.onerror = function() {
n(o.statusText);
}, "POST" === i ? (o.setRequestHeader("Content-Type", "application/json"), o.send(JSON.stringify(a))) : o.send();
} catch (e) {
n(e);
}
});
}
y({
action: "push-get-data",
listener: function(e) {
var t = e.extra, n = e.meta, o = (t || {}).templateId;
if (o && Ee[o] && Ee[o].length) {
var i = Ee[o].shift();
0 === (null == n ? void 0 : n.errCode) ? i.resolve(t) : i.reject(n);
}
}
}), function(e) {
e.Channel = "get_app_channel", e.PlacementId = "get_placement_id", e.IsMobileLogin = "get_is_mobile_login";
}(Oe || (Oe = {})), y({
action: "ai-get-message-count",
listener: function(e) {
var n = e.extra, o = e.meta;
0 === (null == o ? void 0 : o.errCode) && n ? t.emit(LIB.EventType.CustomerUnreadMsg, n) : m("ai-get-message-count err", o, n);
}
});
var De = function() {
var e = "-test";
return "Prod" !== ve.env && "Production" !== ve.env && 0 !== ve.env && ve.env || (e = ""), 
"https://".concat([ "", "tp-", "asia-", "us-" ][ve.apmPostArea], "comb-active").concat(e, ".hortorgames.com/comb-active-server/api/v1/");
}, qe = Object.freeze({
__proto__: null,
ENV: {
Development: "Dev",
Test: "Test",
Production: "Prod"
},
LogType: {
Ali: 1,
TGA: 2,
STD: 4,
Platform: 8
},
EventType: {
Track: "track",
UserSet: "user_set",
UserSetOnce: "user_setOnce",
UserAdd: "user_add",
UserUnset: "user_unset",
UserDel: "user_del"
},
NoticeType: {
Text: 1,
Image: 2,
TextAndImage: 3,
Scroll: 4,
ScrollAndText: 5,
ScrollAndImage: 6,
All: 7
},
SMSCodeType: {
Login: "login",
Register: "register",
ResetPass: "resetPass",
Binding: "binding"
},
QQScene: {
Friend: 0,
Space: 1
},
WXScene: {
Session: 0,
Timeline: 1,
Favorite: 2,
SpecifiedSession: 3
},
QQMicroAppType: {
Test: 1,
Release: 3
},
WXMicroAppType: {
Release: 0,
Development: 1,
Experience: 2
},
MicroProgramType: {
Release: 0,
Development: 1,
Experience: 2
},
BindPlatformType: {
WX: "app-we",
QQ: "app-qq",
Mobile: "app-mobile",
Apple: "app-apple",
Facebook: "app-facebook",
Google: "app-google"
},
AddicationType: {
QuitGame: 0,
SwitchAccount: 1
},
SwitchStatus: {
Opened: 1,
Closed: 0,
NotConfigured: -1
},
NetworkType: {
WiFi: "wifi",
Cellular: "4g",
Unknown: "unknown"
},
NotifyRepeatType: {
NoRepeat: 0,
Year: 1,
Month: 2,
Day: 3,
Hour: 4,
Minute: 5
},
ApmPostArea: {
Default: 0,
Taiwan: 1,
Asia: 2,
US: 3
},
OverseasCustomerType: {
QiYu: "qiyu",
WorkOrder: "workOrder",
TianYou: "tianyou",
TianYouVip: "tianyouVip"
},
VibrateType: {
Short: 0,
Long: 1
},
TYGameInfoType: {
Sever: "server",
Role: "role",
Level: "level",
Entry: "entry"
},
TapTapMomentsType: {
Open: "open_dynamic",
Request: "request_dynamic",
Entre: "entre_dynamic_scene",
Close: "close_dynamic_scene"
},
init: function(e) {
var o = this;
T = Object.assign(T, e || {});
var i = {
hsdkVersion: "1.8.3",
hideProtocolView: !1
};
return (null == e ? void 0 : e.isHideIOSProtocol) && (i.hideProtocolView = !0), 
new Promise(function(r, a) {
return d(o, void 0, void 0, function() {
var o, s, c;
return p(this, function(l) {
switch (l.label) {
case 0:
return l.trys.push([ 0, 2, , 3 ]), [ 4, S({
action: "game-init",
payload: i
}) ];

case 1:
o = l.sent(), w({
action: "wx-share-get-data"
}), s = [ HSDK.ENV.Production, HSDK.ENV.Test ];
try {
t.emit(LIB.EventType.Init, {
config: {
gameId: null == o ? void 0 : o.gameID,
env: s[null == o ? void 0 : o.env],
gameVersion: null == o ? void 0 : o.gameVersion,
channel: null == o ? void 0 : o.channel,
apmPostArea: e.apmPostArea
},
sysInfo: null == o ? void 0 : o.deviceInfo
});
} catch (e) {
m("apm init", e);
}
return r({
distinctId: null == o ? void 0 : o.distinctId,
gameId: null == o ? void 0 : o.gameID,
env: s[null == o ? void 0 : o.env],
gameVersion: null == o ? void 0 : o.gameVersion,
channel: null == o ? void 0 : o.channel,
rawInfo: o
}), m("/*************************/"), m("Game Version: ", null == o ? void 0 : o.gameVersion), 
m("Game GameId: ", null == o ? void 0 : o.gameID), m("Game Env: ", s[null == o ? void 0 : o.env]), 
m("Game Channel: ", null == o ? void 0 : o.channel), m("Apm Area: ", e.apmPostArea), 
m("HSDK Version: ", "1.8.3"), m("HSDK BuildTime: ", "1/17/2025, 3:00:52 PM"), m("HSDK Runtime: ", n ? "cocos" : "egret"), 
m("/*************************/"), [ 3, 3 ];

case 2:
return c = l.sent(), a(c), [ 3, 3 ];

case 3:
return [ 2 ];
}
});
});
});
},
dialogLogin: function(e) {
return void 0 === e && (e = {
isHiddenClose: !1,
agreeProtocol: !1
}), void 0 === e.isHiddenClose && (e.isHiddenClose = !1), void 0 === e.agreeProtocol && (e.agreeProtocol = !1), 
S({
action: "user_login_show_dialog",
payload: e,
apiType: b
});
},
oneKeyLogin: function() {
return S({
action: "start_onekey_auth",
apiType: b
});
},
tryLogin: function() {
return S({
action: "user-tokenlogin",
apiType: b
});
},
qqLogin: function() {
return S({
action: "qq_login",
apiType: b
});
},
wechatLogin: x,
login: L,
visitorLogin: C,
weakLogin: _,
smsLogin: function(e) {
return (null == e ? void 0 : e.phoneNumber) && (e.mobile = e.phoneNumber), S({
action: "user-mobile-login",
payload: e,
apiType: b
});
},
getIsSupportAppleLogin: function() {
return S({
action: "apple_is_support_login"
});
},
appleLogin: function() {
return S({
action: "apple_get_login_code",
apiType: b
});
},
sendSMSCode: function(e) {
return void 0 !== e.phoneNumber && (e.accountNum = e.phoneNumber), void 0 !== e.smsCodeType ? e.verifyCodeTp = e.smsCodeType : e.verifyCodeTp = HSDK.SMSCodeType.Login, 
S({
action: "send_verify_code",
payload: e
});
},
bindPlatform: function(e) {
return new Promise(function(t, n) {
S({
action: "user-bind-platform",
payload: e
}).then(function(e) {
(null == e ? void 0 : e.extra) ? (e.newLoginTpInfo = e.extra, t(e)) : n(e);
}).catch(function(e) {
n(e);
});
});
},
getUserInfo: function() {
return S({
action: "user-getuserinfo"
});
},
logout: function() {
return S({
action: "user-logout"
});
},
syncWxUserInfo: function() {
return S({
action: "sdk-sync-wx-userinfo"
});
},
onLogin: function(e) {
t.on(LIB.EventType.Login, function(t) {
var n = (t || {}).userId;
e.listener({
userSdk: u({
uniqueId: n
}, t)
});
});
},
facebookLogin: function() {
return S({
action: "user-facebook-login"
});
},
googleLogin: function() {
return S({
action: "user-google-login"
});
},
yybLogin: function() {
return S({
action: "yyb-getcode"
});
},
showExitGameDialog: function() {
return w({
action: "exit-dialog"
});
},
applePay: function(e) {
return S({
action: "iap-purchase",
payload: e
});
},
onApplePaySupplement: function(e) {
I({
action: "iap-register-supplement",
listener: null == e ? void 0 : e.listener
});
},
createAppleOrder: function(e) {
return S({
action: "iap-get-order-id",
payload: e
});
},
dialogPay: function(e) {
return S({
action: "show-pay-dialog",
payload: e
});
},
getPayCurrency: function(e) {
return e ? void 0 !== e.isUseCache && null !== e.isUseCache || (e.isUseCache = !1) : e = {
isUseCache: !1
}, S({
action: "sdk-get-pay-currency",
payload: e
});
},
_createTestOrder: function(e) {
return S({
action: "create-order-test-only",
payload: e
});
},
share: function(e) {
return e.shareTypeNameEn = e.id + P, e.shareTitle = e.title, e.shareImgUrl = e.imageUrl, 
e.shareDescription = e.desc, e.shareLinkUrl = e.link, e.wechatRawId && (e.wechatId = e.wechatRawId), 
!i && e.imagePath ? new Promise(function(t, n) {
A({
filePath: e.imagePath
}).then(function(o) {
e.imagePath = o.filePath, S({
action: "user-share-by-view",
payload: e
}).then(function() {
return t({
errMsg: ""
});
}).catch(function(e) {
return n(e);
});
}).catch(function(e) {
n(e);
});
}) : new Promise(function(t, n) {
S({
action: "user-share-by-view",
payload: e
}).then(function() {
return t({
errMsg: ""
});
}).catch(function(e) {
return n(e);
});
});
},
getShareDataList: R,
getShareData: function(e) {
return new Promise(function(t, n) {
R().then(function(o) {
var i = null == e ? void 0 : e.id;
if (i) if (o && o[i + P] && o[i + P].length) {
var r = o[i + P], a = r[Math.floor(Math.random() * r.length)];
t({
title: a.shareTitle,
imageUrl: a.shareImgUrl,
desc: a.shareDescription,
shareSuccessDiff: a.shareSuccessDiff
});
} else n({
errMsg: "can't find share data"
}); else n({
errMsg: "id can't be empty"
});
}).catch(function(e) {
n(e);
});
});
},
onQueryChange: function(e) {
void 0 === e && (e = {
listener: function() {}
});
var t = e.listener, n = null;
y({
action: "send-url-param",
canAddListener: !0,
listener: function(e) {
var t = e.meta, o = e.extra;
t && 0 === t.errCode && o && (Object.keys(o).forEach(function(e) {
o[e] = decodeURIComponent(o[e]);
}), n = o);
}
}), n && (t(n), n = ""), setInterval(function() {
n && (t(n), n = "");
}, 500);
},
qqShareImage: function(e) {
return S({
action: "qq-image-share-by-path",
payload: e
});
},
qqShareImageAndText: function(e) {
return S({
action: "qq-share-url-by-path",
payload: e
});
},
qqShareMicroApp: function(e) {
return S({
action: "qq-share-miniprogram",
payload: e
});
},
wxShareImage: function(e) {
return S({
action: "wx-share-imgpath",
payload: e
});
},
wxShareImageAndText: function(e) {
return S({
action: "wx-share-url-by-path",
payload: e
});
},
wxShareMicroApp: function(e) {
return e.disableForward = e.isDisableForward ? 1 : 0, e.withShareTicket = e.isWithShareTicket ? 1 : 0, 
S({
action: "wx-share-miniprogram",
payload: e
});
},
facebookShare: function(e) {
return S({
action: "user-share-to-platform",
payload: e
});
},
overseaMultiPlatformShare: function(e) {
return S({
action: "user-share-to-platform",
payload: e
});
},
getNotice: function(e) {
return void 0 === e && (e = {}), d(this, void 0, void 0, function() {
return p(this, function() {
return [ 2, new Promise(function(t, n) {
S({
action: "get-notice-info",
payload: e
}).then(function(e) {
var n;
t({
list: (null === (n = null == e ? void 0 : e.list) || void 0 === n ? void 0 : n.map(function(e) {
return e.content = Q(e.content), e;
})) || []
});
}).catch(function(e) {
n(e);
});
}) ];
});
});
},
getNoticeInfo: function(e) {
return void 0 === e && (e = {}), d(this, void 0, void 0, function() {
return p(this, function() {
return [ 2, new Promise(function(t, n) {
S({
action: "get-notice-info",
payload: e
}).then(function(e) {
var n;
t((null === (n = null == e ? void 0 : e.list) || void 0 === n ? void 0 : n.map(function(e) {
return e.content = Q(e.content), e;
})) || []);
}).catch(function(e) {
n(e);
});
}) ];
});
});
},
getFilePath: A,
downloadFile: function(e) {
void 0 === e && (e = {}), void 0 !== (null == e ? void 0 : e.url) && (e.downloadUrl = e.url), 
void 0 !== (null == e ? void 0 : e.isAutoInstall) ? e.isInstallApk = e.isAutoInstall : e.isInstallApk = !0, 
void 0 === (null == e ? void 0 : e.md5) && (e.md5 = ""), (null == e ? void 0 : e.fileName) && (e.saveFile = e.fileName), 
I({
payload: e,
action: "download_file",
listener: function(t) {
var n = t.extra, o = t.meta;
o && 0 !== o.errCode ? g(null == e ? void 0 : e.onError, o) : o && 0 === o.errCode ? (n && "onStart" === n.status && g(null == e ? void 0 : e.onStart), 
n && "onProgress" === n.status && g(null == e ? void 0 : e.onProgress, n.progress), 
n && "onComplete" === n.status && g(null == e ? void 0 : e.onComplete)) : g(null == e ? void 0 : e.onError, o);
}
});
},
saveImage: function(e) {
return S({
action: "save-image",
payload: e
});
},
chooseImage: function(e) {
return S({
action: "sdk-read-image",
payload: e
});
},
getIsInstalledWX: function() {
return S({
action: "wx-isinstalled"
});
},
getIsInstalledQQ: function() {
return S({
action: "qq-isinstalled"
});
},
jumpGsMiniProgram: function(e) {
return S({
action: "wx-jump-miniprogram",
payload: e
});
},
getGsSetting: function() {
return S({
action: "wx-get-jump-info"
});
},
getRTCToken: function(e) {
return S({
action: "get_rtc_token",
payload: e
});
},
getAsrInstance: function(e) {
return X || (X = new W(e)), X;
},
postAPMLog: function(e) {
me.notify(e);
},
onAddictionQuit: function(e) {
I({
action: "game_addiction_quit",
canAddListener: !0,
listener: function() {
g(null == e ? void 0 : e.listener);
}
});
},
sharePointShow: function() {},
setGameUserInfo: function(e) {
e && e.tgaInfo && Le({
eventType: HSDK.EventType.UserSet,
customData: e.tgaInfo,
eventName: ""
});
},
gameTrack: Le,
setTGAUserAccountId: function(e) {
S({
action: "user_account_id",
payload: e
}).then(function() {}).catch(function(e) {
m("err", e);
});
},
postGameInfo: function(e) {
void 0 === e && (e = {}), w({
action: "sdk-get-game-info",
payload: {
roleName: e.roleName,
roleLevel: e.roleLevel,
realmId: e.zoneId,
realmName: e.zoneName,
chapter: e.chapter
}
});
},
afReport: function(e) {
w({
action: "report_af_log_post",
payload: e
});
},
showAppComment: function(e) {
w({
action: "show-inapp-comment",
payload: e
});
},
deleteAppleAccount: function() {
return S({
action: "apple-user-delete"
});
},
preloadAd: function(e) {
if (null == e ? void 0 : e.id) {
var t = e.id;
e.placementId = t;
var n = Ce[t];
if (n && "loading" === n.status) return n.promise;
Ce[t] = {
status: "loading"
}, n = Ce[t];
var o = function(e, t) {
var n;
t.status = "loadFail", t.loadFailReason = e, t.isImmediateShow && g(null === (n = t.showOption) || void 0 === n ? void 0 : n.onLoadFail, e);
};
return I({
action: "preload_ad",
payload: e,
listener: function(e) {
var t = e.extra, i = e.meta;
if (0 === (null == i ? void 0 : i.errCode)) {
var r = t.placementId, a = t.callbackName;
if (Ce[r]) {
var s = Ce[r];
"onAdLoaded" === a || "yh_loadSuccess" === a ? (s.resolve(t), s.status = "loaded", 
s.loadedRes = t, s.isImmediateShow && _e(s.showOption)) : "onAdFailed" !== a && "yh_loadFailed" !== a || (s.reject(t), 
o(t, s));
}
} else {
n.reject(i);
r = t.placementId;
if (Ce[r]) {
s = Ce[r];
o(i, s);
}
}
}
}), n.promise = new Promise(function(e, t) {
n.resolve = e, n.reject = t, n.hasReward = !1;
}), n.promise;
}
},
showAd: _e,
hideAd: function(e) {
if (null == e ? void 0 : e.id) {
e.placementId = e.id;
var t = Ce[e.id];
t && "loading" === t.status && (t.isImmediateShow = !1);
}
return new Promise(function(t, n) {
S({
action: "hide_topon_banner",
payload: e
}).then(function(e) {
t(e);
}).catch(function(e) {
n(e);
});
});
},
preloadBannerAd: function(e) {
return e.style ? e.extra = Object.assign({
left: 0,
top: 0,
width: 320,
height: 50
}, e.style) : e.extra = {
left: 0,
top: 0,
width: 320,
height: 50
}, (null == e ? void 0 : e.id) && (e.placementId = e.id), new Promise(function(t, n) {
S({
action: "preload_topon_banner_ad",
payload: e
}).then(function(o) {
(null == o ? void 0 : o.placementId) === e.id && ("onBannerLoaded" === (null == o ? void 0 : o.callbackName) ? t(o) : (null == o || o.callbackName, 
n(o)));
}).catch(function(e) {
n(e);
});
});
},
showBannerAd: function(e) {
(null == e ? void 0 : e.id) && (e.placementId = e.id), I({
action: "show_topon_banner",
payload: e,
listener: function(t) {
var n = t.extra || {}, o = n.callbackName, r = n.param, a = n.error, s = n.errCode;
a && !i && (r = Q(r)), "onBannerShow" === o ? g(null == e ? void 0 : e.onShowSuccess, r) : "onBannerClose" === o ? g(null == e ? void 0 : e.onClose, r) : "onBannerAutoRefreshed" === o ? g(null == e ? void 0 : e.onRefreshSuccess, r) : "onBannerAutoRefreshFail" === o ? g(null == e ? void 0 : e.onRefreshFail, {
errCode: s,
error: null == a ? void 0 : a.errMsg
}) : "onBannerClicked" === o ? g(null == e ? void 0 : e.onClick, r) : "onBannerDeepLinkOrJump" === o && g(null == e ? void 0 : e.onDeepLinkOrJump, r);
}
});
},
closeBannerAd: function(e) {
return (null == e ? void 0 : e.id) && (e.placementId = e.id), new Promise(function(t, n) {
S({
action: "hide_topon_banner",
payload: e
}).then(function(e) {
t(e);
}).catch(function(e) {
n(e);
});
});
},
preloadInterstitialAd: function(e) {
return (null == e ? void 0 : e.id) && (e.placementId = e.id), new Promise(function(t, n) {
S({
action: "preload_topon_interstitial_video_ad",
payload: e
}).then(function(o) {
o.placementId === e.id && ("onInterstitialAdLoaded" === (null == o ? void 0 : o.callbackName) ? t(o) : (null == o || o.callbackName, 
n(o)));
}).catch(function(e) {
n(e);
});
});
},
showInterstitialAd: function(e) {
(null == e ? void 0 : e.id) && (e.placementId = e.id), I({
payload: e,
action: "show_topon_interstitial_ad",
listener: function(t) {
var n = t.extra || {}, o = n.callbackName, r = n.param, a = n.error;
n.errCode, n.placementId === e.id && (a && !i && (r = Q(r)), "onInterstitialAdShow" === o ? g(null == e ? void 0 : e.onShowSuccess, r) : "onInterstitialAdClose" === o ? g(null == e ? void 0 : e.onClose, r) : "onInterstitialAdVideoStart" === o ? g(null == e ? void 0 : e.onPlayStart, r) : "onInterstitialAdVideoEnd" === o ? g(null == e ? void 0 : e.onPlayEnd, r) : "onInterstitialAdVideoError" === o ? g(null == e ? void 0 : e.onPlayFail, r) : "onInterstitialAdClicked" === o ? g(null == e ? void 0 : e.onClick, r) : "onInterstitialDeepLinkOrJump" === o && g(null == e ? void 0 : e.onDeepLinkOrJump, r));
}
});
},
preloadVideoAd: function(e) {
return (null == e ? void 0 : e.id) && (e.placementId = e.id), new Promise(function(t, n) {
S({
action: "preload_topon_reward_video_ad",
payload: e
}).then(function(o) {
o.placementId === e.id && ("onRewardedVideoAdLoaded" === (null == o ? void 0 : o.callbackName) ? t(o) : (null == o || o.callbackName, 
n(o)));
}).catch(function(e) {
n(e);
});
});
},
showVideoAd: function(e) {
(null == e ? void 0 : e.id) && (e.placementId = e.id);
var t = !1;
I({
action: "show_topon_reward_video_ad",
payload: e,
listener: function(n) {
var o = n.extra || {}, r = o.callbackName, a = o.param, s = o.error, c = o.errCode;
o.placementId === e.id && (s && !i && (a = Q(a)), "onReward" === r ? (g(null == e ? void 0 : e.onReward, a), 
t = !0) : "onRewardedVideoAdPlayFailed" === r ? g(null == e ? void 0 : e.onPlayFail, {
errCode: c,
errMsg: null == s ? void 0 : s.errMsg
}) : "onRewardedVideoAdClosed" === r ? (g(t ? null == e ? void 0 : e.onFinishClose : null == e ? void 0 : e.onQuitClose, a), 
g(null == e ? void 0 : e.onClose, a)) : "onRewardedVideoAdPlayStart" === r ? g(null == e ? void 0 : e.onPlayStart, a) : "onRewardedVideoAdPlayEnd" === r ? g(null == e ? void 0 : e.onPlayEnd, a) : "onRewardedVideoAdPlayClicked" === r ? g(null == e ? void 0 : e.onClick, a) : "onRewardDeepLinkOrJump" === r && g(null == e ? void 0 : e.onDeepLinkOrJump, a));
}
});
},
show233Ad: function(e) {
(null == e ? void 0 : e.id) && (e.advId = e.id), I({
action: "show_ad_233",
payload: e,
listener: function(t) {
var n = t.extra || {}, o = n.callbackName, i = n.param;
n.error, n.errCode, "onVideoShow" === o ? g(null == e ? void 0 : e.onShowSuccess, i) : "onVideoShowSkip" === o ? g(null == e ? void 0 : e.onSkip, i) : "onVideoShowFail" === o ? g(null == e ? void 0 : e.onShowFail, i) : "onVideoReward" === o ? g(null == e ? void 0 : e.onReward, i) : "onVideoClose" === o ? g(null == e ? void 0 : e.onClose, i) : "onVideoClick" === o && g(null == e ? void 0 : e.onClick, i);
}
});
},
checkSwitches: function(e) {
return (null == e ? void 0 : e.params) && (e.defCustomParams = e.params, e.params.nickName && (e.nickName = e.params.nickName)), 
e.sequence = Ae, w({
action: Re,
payload: e
}), new Promise(function(t, n) {
Pe[Ae] = {
resolve: t,
reject: n,
switchIdList: null == e ? void 0 : e.switchIdList,
hasHandled: !1
}, Ae++;
});
},
checkNotifyAuth: function(e) {
return new Promise(function(t, n) {
S({
action: "push-check-permission",
payload: e
}).then(function(e) {
t(e);
}).catch(function(e) {
n(e);
});
});
},
getNotifyData: function(e) {
var t = (e || {}).templateId;
return void 0 === Ee[t] && (Ee[t] = []), new Promise(function(n, o) {
w({
action: "push-get-data",
payload: e
}), Ee[t].push({
resolve: n,
reject: o
});
});
},
pushLocalNotify: function(e) {
w({
action: "push-add-localnotifi",
payload: e
});
},
removeLocalNotify: function(e) {
w({
action: "push-remove-localnotifi",
payload: e
});
},
openNotifyAction: function(e) {
w({
action: "push-start-notifi",
payload: e
});
},
stopNotifyAction: function(e) {
w({
action: "push-stop-notifi",
payload: e
});
},
stopLocalNotifyAction: function(e) {
w({
action: "push-remove-all-localnotifi",
payload: e
});
},
getNotifyWithLaunch: function(e) {
y({
action: "push-handle-message",
listener: function(t) {
var n = t.extra;
g(null == e ? void 0 : e.listener, n);
}
});
},
onPushMsg: function(e) {
I({
action: "push-onmessage",
listener: function(t) {
var n = t.extra;
t.meta, g(null == e ? void 0 : e.listener, n);
}
});
},
pushMsgSetUserTags: function(e) {
return S({
action: "push-set-tags",
payload: e
});
},
pushMsgSetAlias: function(e) {
return S({
action: "push-setalias",
payload: e
});
},
pushMsgResetAlias: function(e) {
return S({
action: "push-unsetalias",
payload: e
});
},
pushMsgSetBadge: function(e) {
return S({
action: "push-setbadge",
payload: e
});
},
pushMsgResetBadge: function() {
return S({
action: "push-reset-badge"
});
},
pushMsgClear: function() {
return S({
action: "push-clearallnotice"
});
},
onPushMsgOnlineStateChange: function(e) {
I({
action: "on-receive-online-tate",
listener: function(t) {
var n = t.extra;
t.meta, g(null == e ? void 0 : e.listener, n);
}
});
},
onPushMsgCommandChange: function(e) {
I({
action: "on-receive-command-result",
listener: function(t) {
var n = t.extra;
t.meta, g(null == e ? void 0 : e.listener, n);
}
});
},
onPushMsgArrivedChange: function(e) {
I({
action: "on-notification-message-arrived",
listener: function(t) {
var n = t.extra;
t.meta, g(null == e ? void 0 : e.listener, n);
}
});
},
onPushMsgClick: function(e) {
I({
action: "on-notification-message-clicked",
listener: function(t) {
var n = t.extra;
t.meta, g(null == e ? void 0 : e.listener, n);
}
});
},
onPushMsgPID: function(e) {
I({
action: "on-receive-service-pid",
listener: function(t) {
var n = t.extra;
t.meta, g(null == e ? void 0 : e.listener, n);
}
});
},
onPushMsgClientId: function(e) {
I({
action: "on-receive-client-id",
listener: function(t) {
var n = t.extra;
t.meta, g(null == e ? void 0 : e.listener, n);
}
});
},
pushLocalNotice: function(e) {
return e.repeats = e.isRepeat, S({
action: "push-addlocal-notce",
payload: e
});
},
setRealNameAuth: function(e) {
return void 0 === e && (e = {
isHiddenClose: !1
}), void 0 === e.isHiddenClose && (e.isHiddenClose = !1), S({
action: "real_name_show_auth",
payload: e
});
},
getRealNameInfo: function() {
return S({
action: "get_real_name_info"
});
},
showLoading: function(e) {
void 0 === e && (e = {}), void 0 === e.title && (e.title = ""), w({
action: "show_loading",
payload: e
});
},
hideLoading: function() {
w({
action: "hide_loading"
});
},
showAlert: function(e) {
S({
action: "sdk-alert",
payload: e
}).then(function(t) {
g(e.onClick, t);
}).catch(function(e) {
!function() {
for (var e = [], t = 0; t < arguments.length; t++) e[t] = arguments[t];
m.apply(void 0, f([ "[!!!error!!!]" ], e));
}("showAlert err", e);
});
},
showModal: function(e) {
return new Promise(function(t, n) {
e.cancel = !0, !1 === e.showCancel && (e.cancel = !1), e.actionText = e.confirmText || "确定", 
e.cancelText = e.cancelText || "取消", e.message = e.content || " ", e.title = e.title || " ", 
S({
action: "sdk-alert",
payload: e
}).then(function(e) {
var n = e.action;
"action" === n ? t({
confirm: !0,
cancel: !1
}) : "cancel" === n && t({
cancel: !0,
confirm: !1
});
}).catch(function(e) {
n(e);
});
});
},
exitApp: function() {
w({
action: "sdk-exitApplication"
});
},
onShow: function(e) {
y({
action: "app-activity-resume",
canAddListener: !0,
listener: function() {
g(null == e ? void 0 : e.listener);
}
});
},
onHide: function(e) {
y({
action: "app-activity-pause",
canAddListener: !0,
listener: function() {
g(null == e ? void 0 : e.listener);
}
});
},
getBuildKey: function() {
var e = {
channel: "get_app_channel",
placementId: "get_placement_id",
isMobileLogin: "get_is_mobile_login"
}, t = {}, n = 0;
return new Promise(function(o, i) {
var r = Object.keys(e);
r.forEach(function(a) {
S({
action: e[a]
}).then(function(e) {
t = Object.assign(t, e), ++n === r.length && o(t);
}).catch(function(e) {
i(e);
});
});
});
},
openApp: function(e) {
w({
action: "weibo-user-profile-page",
payload: e
});
},
getBrightness: function() {
return new Promise(function(e, t) {
S({
action: "sdk-get-brightness"
}).then(e).catch(t);
});
},
setBrightness: function(e) {
w({
action: "sdk-set-brightness",
payload: e
});
},
getBattery: function() {
return new Promise(function(e, t) {
S({
action: "sdk-get-battery"
}).then(function(t) {
return e(t);
}).catch(t);
});
},
getNetworkType: function() {
return new Promise(function(e, t) {
S({
action: "sdk-get-network"
}).then(function(n) {
null != n.networkType && "string" == typeof n.networkType ? (n = Object.assign({
networkType: n.networkType.toLowerCase()
}), e(n)) : t({
networkType: "unknown",
errMsg: "native not support!"
});
}).catch(function(e) {
t({
networkType: "unknown",
errMsg: e
});
});
});
},
setClipboard: function(e) {
w({
action: "sdk-sync-passbord",
payload: e
});
},
getClipboard: function() {
return new Promise(function(e, t) {
S({
action: "sdk-get-passbord"
}).then(function(t) {
var n = Q(t.text);
e({
text: n
});
}).catch(t);
});
},
setKeepScreenOn: function(e) {
return e.keepScreenOn = e.isOn, S({
action: "set-keep-screen-on",
payload: e
});
},
setVibrate: function(e) {
return S({
action: "sdk-vibrate",
payload: e
});
},
onBackBtnTap: function(e) {
t.on(LIB.EventType.BackBtnTap, function() {
console.log("backBtnTapCallback"), e && e();
});
},
selectLocalImage: function() {
return S({
action: "sdk-read-image"
});
},
getDeviceInfo: function() {
return S({
action: "sdk-get-device-info"
});
},
getKeyByKeyType: function(e) {
return new Promise(function(t, n) {
S({
action: "sdk-get-secret",
payload: e
}).then(function(e) {
if (!e.data) throw new Error("");
var n = Q(e.data);
t({
secretKey: n
});
}).catch(function(e) {
n({
errMsg: "公钥获取失败" + JSON.stringify(e)
});
});
});
},
openOverseasCustomer: function(e) {
return S({
action: "sdk-custom-service",
payload: e
});
},
onCustomerUnreadMsg: function(e) {
t.on(LIB.EventType.CustomerUnreadMsg, function(t) {
var n = (t || {}).count;
g(e.listener, {
count: n
});
});
},
getTranslateResult: function(e) {
return new Promise(function(t, n) {
S({
action: "sdk-translation",
payload: e
}).then(function(e) {
e && void 0 !== e.text ? t({
text: Q(e.text)
}) : n({
errMsg: "native trans error",
res: e
});
}).catch(n);
});
},
getFacebookUserInfo: function() {
return S({
action: "sdk-sync-fb-userinfo"
});
},
openWebview: function(e) {
e.isShowUserProtocol && (e.userProtocol = !0), e.isShowUserPrivacy && (e.userPrivacy = !0), 
w({
action: "sdk_open_webview",
payload: e
});
},
checkRunningProcess: function(e) {
return S({
action: "sdk-check-running-process",
payload: e
});
},
showUserCenter: function(e) {
w({
action: "sdk-show-user-center",
payload: e
});
},
registerLogout: function(e) {
y({
action: "user-logout-from-sdk",
listener: function() {
g(null == e ? void 0 : e.listener);
}
});
},
reportTYGameInfo: function(e) {
w({
action: "sdk-report-game-info",
payload: e
});
},
bindEventCallbacks: function(e) {
y({
action: "bind-from-out",
listener: function(t) {
var n = t.extra;
g(null == e ? void 0 : e.listener, n);
}
});
},
openTapTapDetails: function() {
return w({
action: "skip-taptap"
});
},
shareToTapTap: function(e) {
return new Promise(function(t, n) {
S({
action: "share-to-taptap",
payload: e
}).then(function() {
t();
}).catch(function(e) {
n({
errMsg: e || "share taptap failed"
});
});
});
},
tapTapMoments: function(e) {
return w({
action: "taptap-dynamic-action",
payload: {
dynamic: e.type,
scene_id: e.sceneId
}
});
},
onTapTapCallback: function(e) {
y({
action: "taptap-callback-action",
listener: function(t) {
var n = t.extra;
g(function() {
return null == e ? void 0 : e.listener(n);
});
}
});
},
receiveMsgFromMainModule: function(e) {
t.on(LIB.EventType.Login, function(t) {
var n = (t || {}).userId, o = u(u({
uniqueId: n
}, t), {
gameId: ve.gameId,
env: ve.env
});
m("HSDK receiveMsgFromMainModule", o), e.listener && e.listener(o);
});
},
receiveMsgWhileRunning: function() {
return m("HSDK receiveMsgWhileRunning", {
uniqueId: we.userId,
gameId: ve.gameId,
env: ve.env
}), {
uniqueId: we.userId,
gameId: ve.gameId,
env: ve.env
};
},
getQuestionnaireConfig: function() {
return new Promise(function(e, t) {
Ne({
method: "get",
url: De() + "questionnaires/config?gameId=".concat(ve.gameId)
}).then(function(t) {
m("getQuestionnaireConfig", t), e(t);
}).catch(function(e) {
t(e);
});
});
},
getQuestionnaire: function(e) {
return new Promise(function(t, n) {
Ne({
method: "get",
url: De() + "questionnaires?gameId=".concat(ve.gameId, "&roleLevel=").concat((null == e ? void 0 : e.roleLevel) || 0, "&uniqueId=").concat(we.userId)
}).then(function(e) {
m("getQuestionnaire", e), e && e.questionnaires && e.questionnaires.length > 0 ? t((null == e ? void 0 : e.questionnaires) || []) : n({
errCode: -1,
errMsg: "问卷列表为空"
});
}).catch(function(e) {
n(e);
});
});
},
submitQuestionnaire: function(e) {
return new Promise(function(t, n) {
Ne({
method: "post",
url: De() + "questionnaires/".concat(e.questionnaireId, "/answers"),
params: {
roleId: e.roleId,
roleLevel: e.roleLevel || 0,
startTime: e.startTime,
endTime: e.endTime,
gameId: ve.gameId,
uniqueId: we.userId,
answers: e.answers
}
}).then(function(e) {
m("submitQuestionnaire", e), t(e);
}).catch(function(e) {
n(e);
});
});
}
});
window.HSDK = Object.assign({}, qe), !o && n && (window.HSDK.onMessage = function(e, n) {
if (e === r) try {
JSON.parse(n) && t.emit(LIB.EventType.ReceiveFromNative, n);
} catch (e) {
s(n);
}
});
});