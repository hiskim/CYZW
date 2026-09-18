import Foundation

// MARK: - 抓包 · 页面侧代理
//
// 与 `GameEnhancementScript` 同策略：代理脚本在 `atDocumentStart` **预注入**每个
// 实例（WKUserScript 只能在导航时注入、运行时无法追加），运行时只推开关。
//
// 抓包链路（参考猫助手的页面级 hook + 自助手仓 `wsAgent.js` 的帧语义）：
//
//   游戏 `new WebSocket(...)` → 构造器已被替换 → 实例登记（activeSockets）
//        │  send(data)                      ← 包装（先抓后透传，永不吞帧）
//        │  addEventListener('message')     ← 常驻旁路监听（不碰游戏自己的 handler）
//        ▼
//   字节 → base64 → `webkit.messageHandlers.ios2Game.postMessage({type:'packet',…})`
//        ▼
//   宿主 `PacketCaptureController`：px 信封解封 → BON 解码 → cmd / body → 过滤 + 窗口展示
//
// 反向通道（发送指令）：宿主把**完整帧**（x 信封编码好的字节，base64）经
// `__LOBBY_CAPTURE__.sendRaw(b64)` 交给页面 → 从 `activeSockets` 里挑 OPEN 的游戏
// socket → `socket.send(bytes)`。构帧全在宿主（BonCodec + XorFrameCipher），
// 页面零协议知识、不依赖 `g_utils` 等游戏内部符号；且注入帧会再次经过 send 包装
// 上报抓包流——请求-响应配对照常工作。
//
// 职责红线（与宿主的分工）：
//   · 页面侧**只抓原始字节**，不解 px 信封、不解 BON、不做过滤——解码统一在宿主，
//     过滤条件（包含 / 排除 / 心跳 / 方向）随时可改，无需重新注入页面；
//   · hook 必须**常驻**：开关关闭时 `report()` 直接返回（零开销路径），hook 本身不拆。
//     这样「关掉再开」不需要重载页面，且开启前的帧照旧不收（符合「开启抓包时」语义）；
//   · 永不改写游戏行为：send 包装先抓后透传，message 用 `addEventListener` 挂
//     旁路监听器（同一事件允许多个 listener，与游戏自己的 handler 互不干扰）。
//
// 为什么 hook 构造器而不是学猫助手轮询 `window.ws` / `h5websocket.ws` 等别名：
//   ① 本宿主是 `atDocumentStart` 注入，**一定先于游戏所有脚本**执行——游戏之后
//      `new` 的每一个 WebSocket 都必然经过替换后的构造器，一个都漏不掉；
//   ② 捕获具体对象引用的方案（猫助手 / `ios2-script-runtime.js` 的别名捕获）
//      只能 hook 到「捕获那一刻已存在的对象」，并且要在游戏封装层上逐个适配；
//      构造器层 hook 与封装无关，天然覆盖二进制帧与文本帧，还顺带维护了
//      `activeSockets`——发送指令的出口正是它。
//
// `class extends WebSocket` 的兼容性：WebKit 下实例的 `instanceof WebSocket`
// 仍然成立（原型链通过 `extends` 保持），静态常量（`OPEN` 等）随原型链继承。
// 游戏（Cocos 2.4.9 Web 版）最终走的就是原生 `WebSocket`，无第二通道。
//
// ⚠️ 帧体量护栏：单帧超过 `maxFrameBytes` 时截断上报（base64 也随之变小），
//   顶部截断不影响 cmd 解码（px 头 + BON 外层的 cmd 在前几十字节内）；
//   心跳每 2s 一条由宿主窗口的「排除心跳」开关过滤，页面不特判。
public enum PacketCaptureScript {
    /// 代理脚本版本号。**每次改 `agent` 就 +1**（诊断串里带 `v=`，用于确认页面在跑哪一版）。
    ///
    /// v3（2026-09-18）：① 每个构造的 socket 分配递增编号，上报帧带 `sid`——
    /// 主连接与盐场连接的 URL 都含 "agent"，按 URL 挑发送目标会撞，盐场图表的
    /// 轮询帧必须**定向**发回学到 `war_*` 命令的那条连接；② 单帧上限 192→512 KiB
    /// （`war_getbattlefieldinfo` 的战场快照实测逼近旧上限，截断会让 BON 解不开）。
    public static let agentVersion = "3"

    /// 单帧上报字节上限（512 KiB）。超出部分丢弃并打 `trunc` 标记。
    private static let maxFrameBytes = 512 * 1024

    /// 推一次开关（幂等，可重复调用）。返回页面侧诊断串：
    /// `capture v=1 hooked=1 enabled=true total=1 sent=23 dropped=0`；
    /// 代理不存在时返回 `no-handler`（页面未装代理脚本 / 构建产物未更新）。
    public static func setEnabled(_ enabled: Bool) -> String {
        "window.__LOBBY_CAPTURE__ ? window.__LOBBY_CAPTURE__.setEnabled(" +
            "\(enabled ? "true" : "false")" + ") : 'no-handler'"
    }

    /// 只读诊断：页面侧 hook 与上报计数。
    public static func status() -> String {
        "window.__LOBBY_CAPTURE__ ? window.__LOBBY_CAPTURE__.status() : 'no-handler'"
    }

    /// 发送一帧（base64 编码的完整 x 信封帧，由宿主构好）。
    /// `socketID` ≥ 0 时定向发给该编号的 socket（盐场轮询用）；否则按旧口径挑。
    /// 返回诊断串：`sent bytes=N socket=…` / `no-open-socket …` / `no-handler`。
    public static func sendRaw(_ base64: String, socketID: Int = -1) -> String {
        let target = socketID >= 0 ? String(socketID + 1) : "0"
        return "window.__LOBBY_CAPTURE__ ? window.__LOBBY_CAPTURE__.sendRaw('\(base64)', \(target)) : 'no-handler'"
    }

    /// 代理脚本本体（`atDocumentStart` 注入，只注入主框架）。
    public static let agent: String = {
        let version = agentVersion
        let maxBytes = maxFrameBytes
        return """
        (() => {
          if (window.__LOBBY_CAPTURE__) return;

          const VERSION = '\(version)';
          const MAX_FRAME_BYTES = \(maxBytes);
          const channel = (window.webkit && window.webkit.messageHandlers &&
                           window.webkit.messageHandlers.ios2Game) || null;

          const state = { enabled: false, hooked: 0, sent: 0, dropped: 0, nextSocketID: 1, sockets: new Map() };

          // 字节 → base64。分块拼二进制串再 btoa：大帧一次性 apply 会撞参数个数上限。
          function toBase64(bytes) {
            let binary = '';
            const CHUNK = 0x8000;
            for (let i = 0; i < bytes.length; i += CHUNK) {
              binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
            }
            return btoa(binary);
          }

          // base64 → 字节（sendRaw 用）。
          function fromBase64(base64) {
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            return bytes;
          }

          // 统一上报入口。开关关闭时是零开销路径（第一行就返回）。
          // sid = 发出/收到该帧的 socket 编号（v3；宿主用它做定向发送）。
          function report(direction, data, sid) {
            if (!state.enabled || !channel) return;
            try {
              let bytes;
              if (typeof data === 'string') {
                bytes = new TextEncoder().encode(data);
              } else if (data instanceof ArrayBuffer) {
                bytes = new Uint8Array(data);
              } else if (ArrayBuffer.isView(data)) {
                bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
              } else {
                return; // Blob 走 reportBlob 的异步路径，其它类型不认识就放行。
              }
              const total = bytes.length;
              let truncated = false;
              if (total > MAX_FRAME_BYTES) {
                bytes = bytes.subarray(0, MAX_FRAME_BYTES);
                truncated = true;
              }
              state.sent++;
              channel.postMessage({
                type: 'packet',
                dir: direction,
                kind: (typeof data === 'string') ? 'text' : 'binary',
                b64: toBase64(bytes),
                len: total,
                trunc: truncated,
                sid: sid || 0,
                ts: Date.now()
              });
            } catch (error) {
              state.dropped++;
            }
          }

          // Blob 只可能出现在接收侧（binaryType 缺省值）；异步读完再走同一条上报通道。
          function reportBlob(direction, blob, sid) {
            if (!state.enabled || !channel) return;
            blob.arrayBuffer().then(function (buffer) {
              report(direction, buffer, sid);
            }).catch(function () {});
          }

          // ── hook：替换构造器（extends 保持 instanceof 与静态常量）──
          const NativeWebSocket = window.WebSocket;
          class LobbyCaptureWebSocket extends NativeWebSocket {
            constructor(url, protocols) {
              super(url, protocols);
              state.hooked++;
              // 递增编号（从 1 起；0 是宿主侧「未知 socket」的哨兵值）。
              const sid = state.nextSocketID++;
              state.sockets.set(this, sid);
              this.__lobbySocketID = sid;
              // 关闭 / 失败时摘出登记表，发送指令只挑还活着的连接。
              this.addEventListener('close', function () { state.sockets.delete(this); });
              this.addEventListener('error', function () { state.sockets.delete(this); });
              this.addEventListener('message', function (event) {
                if (event.data instanceof Blob) reportBlob('recv', event.data, sid);
                else report('recv', event.data, sid);
              });
            }
            send(data) {
              if (data instanceof Blob) reportBlob('send', data, this.__lobbySocketID);
              else report('send', data, this.__lobbySocketID);
              return super.send(data);
            }
          }
          try {
            window.WebSocket = LobbyCaptureWebSocket;
          } catch (error) {
            // 理论上不可达（window 属性可写）；保守起见不阻断页面。
          }

          // 发送指令：targetID > 0 → 定向发给该编号的 socket（盐场轮询的主路径）；
          // 否则按旧口径挑 OPEN 的游戏连接（优先 agent 端点）。字节原样交出。
          // 注入帧会经过上面的 send 包装 → 正常上报抓包流，配对逻辑不受影响。
          function sendRaw(base64, targetID) {
            const open = Array.from(state.sockets.entries()).map(function (entry) {
              return { socket: entry[0], sid: entry[1] };
            }).filter(function (item) {
              return item.socket.readyState === 1;
            });
            if (!open.length) {
              return 'no-open-socket hooked=' + state.hooked;
            }
            let target = null;
            if (targetID > 0) {
              target = open.find(function (item) { return item.sid === targetID; }) || null;
            }
            if (!target) {
              target = open.find(function (item) {
                return (item.socket.url || '').indexOf('agent') >= 0;
              }) || open[open.length - 1];
            }
            try {
              const bytes = fromBase64(base64);
              target.socket.send(bytes);
              return 'sent sid=' + target.sid + ' bytes=' + bytes.length + ' socket=' + (target.socket.url || '').slice(0, 60);
            } catch (error) {
              return 'send-failed ' + (error && error.message ? error.message : String(error));
            }
          }

          window.__LOBBY_CAPTURE__ = {
            version: VERSION,
            setEnabled(enabled) {
              state.enabled = !!enabled;
              return 'capture v=' + VERSION + ' hooked=' + state.hooked +
                     ' open=' + Array.from(state.sockets.keys()).filter(function (s) { return s.readyState === 1; }).length +
                     ' enabled=' + state.enabled +
                     ' sent=' + state.sent + ' dropped=' + state.dropped;
            },
            status() {
              return 'capture v=' + VERSION + ' hooked=' + state.hooked +
                     ' open=' + Array.from(state.sockets.keys()).filter(function (s) { return s.readyState === 1; }).length +
                     ' enabled=' + state.enabled +
                     ' sent=' + state.sent + ' dropped=' + state.dropped;
            },
            sendRaw: sendRaw
          };
        })();
        """
    }()
}
