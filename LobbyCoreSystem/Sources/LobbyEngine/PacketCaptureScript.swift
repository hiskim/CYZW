import Foundation

// MARK: - 抓包 · 页面侧代理
//
// 与 `GameEnhancementScript` 同策略：代理脚本在 `atDocumentStart` **预注入**每个
// 实例（WKUserScript 只能在导航时注入、运行时无法追加），运行时只推开关。
//
// 抓包链路（参考猫助手的页面级 hook + 自助手仓 `wsAgent.js` 的帧语义）：
//
//   游戏 `new WebSocket(...)` → 构造器已被替换 → 实例登记
//        │  send(data)                      ← 包装（先抓后透传，永不吞帧）
//        │  addEventListener('message')     ← 常驻旁路监听（不碰游戏自己的 handler）
//        ▼
//   字节 → base64 → `webkit.messageHandlers.ios2Game.postMessage({type:'packet',…})`
//        ▼
//   宿主 `PacketCaptureController`：px 信封解封 → BON 解码 → cmd / body → 过滤 + 窗口展示
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
//      构造器层 hook 与封装无关，天然覆盖二进制帧与文本帧。
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
    public static let agentVersion = "1"

    /// 单帧上报字节上限（192 KiB）。超出部分丢弃并打 `trunc` 标记。
    private static let maxFrameBytes = 192 * 1024

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

          const state = { enabled: false, hooked: 0, sent: 0, dropped: 0 };

          // 字节 → base64。分块拼二进制串再 btoa：大帧一次性 apply 会撞参数个数上限。
          function toBase64(bytes) {
            let binary = '';
            const CHUNK = 0x8000;
            for (let i = 0; i < bytes.length; i += CHUNK) {
              binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
            }
            return btoa(binary);
          }

          // 统一上报入口。开关关闭时是零开销路径（第一行就返回）。
          function report(direction, data) {
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
                ts: Date.now()
              });
            } catch (error) {
              state.dropped++;
            }
          }

          // Blob 只可能出现在接收侧（binaryType 缺省值）；异步读完再走同一条上报通道。
          function reportBlob(direction, blob) {
            if (!state.enabled || !channel) return;
            blob.arrayBuffer().then(function (buffer) {
              report(direction, buffer);
            }).catch(function () {});
          }

          // ── hook：替换构造器（extends 保持 instanceof 与静态常量）──
          const NativeWebSocket = window.WebSocket;
          class LobbyCaptureWebSocket extends NativeWebSocket {
            constructor(url, protocols) {
              super(url, protocols);
              state.hooked++;
              this.addEventListener('message', function (event) {
                if (event.data instanceof Blob) reportBlob('recv', event.data);
                else report('recv', event.data);
              });
            }
            send(data) {
              if (data instanceof Blob) reportBlob('send', data);
              else report('send', data);
              return super.send(data);
            }
          }
          try {
            window.WebSocket = LobbyCaptureWebSocket;
          } catch (error) {
            // 理论上不可达（window 属性可写）；保守起见不阻断页面。
          }

          window.__LOBBY_CAPTURE__ = {
            version: VERSION,
            setEnabled(enabled) {
              state.enabled = !!enabled;
              return 'capture v=' + VERSION + ' hooked=' + state.hooked +
                     ' enabled=' + state.enabled +
                     ' sent=' + state.sent + ' dropped=' + state.dropped;
            },
            status() {
              return 'capture v=' + VERSION + ' hooked=' + state.hooked +
                     ' enabled=' + state.enabled +
                     ' sent=' + state.sent + ' dropped=' + state.dropped;
            }
          };
        })();
        """
    }()
}
