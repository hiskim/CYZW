# profile-fetch-verify —— 协议层的一键验证

用来证明「Swift 移植的游戏私有协议」与助手仓的参考实现**逐字节等价**。
改 `BonCodec.swift` / `XorFrameCipher.swift` / `AccountProfileFetcher.swift` 之后跑一次。

```sh
sh run.sh '23甜阴.bin'        # 参数是基准向量用的账号（选**没在运行**的）
```

## 为什么必须做逐字节对拍，而不是「跑通就行」

BON 的解析是**静默失败**的：解码器与编码器共享一张字符串表，一旦某次 `push` 漏了，
后面所有的 tag 99 引用都会**错位**——读出来的不是报错，而是一堆**看起来很正常、
只是值不对**的字符串。这种 bug 靠肉眼审代码基本发现不了，靠「能跑通」也发现不了。
所以判据只能是：同一份输入，两边产出**逐字符相同**的文本 / 逐字节相同的二进制。

## 三步验证

| 步骤 | 输入 | 判据 |
|---|---|---|
| ① BON 编解码 | 真实 `authuser` 响应（287B）、真实 WSS 响应（12–13 万字节，内层 dump 19 万字符） | 与参考实现的规范化 dump 逐字符一致 |
| ② 帧信封 | 服务端真实信封 + 自封自解 + 故意喂错前缀 | 解出的明文逐字节一致；错前缀必须**明确报错** |
| ③ 端到端 | `.bin` 真实凭据 | 用产品代码走真服务端，取到 `headImg/power/level/name`；若 `avatars.json` 里有同名账号，**自动与页面内探针抓到的值对拍** |

第 ③ 步的「同账号对拍」是最有价值的一步：`avatars.json` 里的值是游戏内
`window.ROLE` 抓的，与 WSS 是**两条独立的链路**，两边数值一致才说明这条路可信。
（这也是发现 `/login/serverlist` 的 `power` 不可信的办法——见
`../ws-profile-probe/README.md`。）

## 踩过的三个坑（都写进脚本注释了）

1. **参考实现的 `decrypt` 是就地修改输入数组的**。生成基准向量时若先解密再存「原始信封」，
   存下来的其实是已解密的帧 → 对拍会得到莫名其妙的失败。必须在解密**之前**存原始字节。
2. **BON 的报文体是「外层 BON 里再嵌一段 BON 字节串」**，要解两层。
   `g_utils.parse(raw).getData()` 取的是**内层**，直接 `bon.decode(raw)` 得到的是外层——
   层级搞错会让 dump 长度相差三个数量级。
3. **ESM 的相对 import 是相对脚本自身解析的**，不是相对 cwd。所以 `make-vectors.mjs`
   必须**拷进工作目录**再跑，否则 `./bonProtocol.js` 找不到。

## 目录

```
run.sh                一键跑完三步
make-vectors.mjs      从真实服务端抓基准向量（含一次 WSS 往返）
parity-bon.swift      BON 编解码对拍
parity-cipher.swift   帧信封对拍
fetch-smoke.swift     端到端抓取 + 同账号数值对拍
```

依赖：`../ws-profile-probe/setup.sh`（现拷 `bonProtocol.js` + 软链 Node 工作区）。
