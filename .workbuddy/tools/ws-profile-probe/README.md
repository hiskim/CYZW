# ws-profile-probe —— 不启动游戏，直接从服务端取账号资料

**结论先行（2026-09-17 实测）**：`/login/authuser` 换一个 `roleToken`，然后连
`wss://xxz-xyzw.hortorgames.com/agent` 发一条 `role_getroleinfo`，
**约 300ms 就能拿到角色的 `headImg` / `power` / `levelId` / `name`**，
完全不需要下载 game bundle、不需要 WKWebView、不需要登录游戏。

参考实现来自助手仓 `/Users/gg/code/xyzw_web_helper`（同一套协议）：
`src/utils/token.ts` / `src/stores/tokenStore.ts:677` / `src/utils/xyzwWebSocket.js`。

## 实测数据

| 账号 | 耗时 | name | levelId | power | headImg 形态 |
|---|---|---|---|---|---|
| `15小惜.bin` | 299ms | 仙✨小妖后 | 8700 | 8,805,351,599 | `mars-face.hortorgames.com`（自建 CDN） |
| `21电阴.bin` | 283ms | 电阴之王 | 9570 | 11,996,504,721 | `thirdwx.qlogo.cn`（微信头像） |
| `31八嘎.bin` | 286ms | 鬼✨八 | 8518 | 8,712,996,974 | `mars-face` |
| `54天蛇.bin` | 279ms | 霸-天蛇 | 8168 | 7,416,990,032 | `mars-face` |

`21电阴.bin` 返回的 `headImg` 与用户当时抓包贴出来的那条链接**逐字节一致**，
证明这条路径拿到的就是游戏自己用的那份数据（`role` 共 139 个字段）。

> 顺带：`avatars.json` 里已有 13 个账号的资料（来自页面内读 `window.ROLE`），
> 这批数值（level 8000–10000 / power 60–138 亿）与 WSS 取值区间完全吻合。

## 三条路对比

| 路径 | 头像 | 战力 | 需要游戏窗口 | 说明 |
|---|---|---|---|---|
| 现状：页面内读 `window.ROLE` | ✅ | ✅ | ✅ 必须跑起来 | 已上线，13/32 账号有资料 |
| `/login/serverlist`（纯 HTTP） | ❌ 无该字段 | ⚠️ **不可信** | ❌ | 见下方警告 |
| `/login/authuser` + WSS `role_getroleinfo` | ✅ | ✅ | ❌ | 本次实测跑通 |

⚠️ **`/login/serverlist` 的 `power` 不能用**：`11不不.bin` 那里返回 3700711（370 万），
而真实战力是 8,844,173,473（88 亿）—— 差 3 个数量级；`level` 还恒为 1。
它只适合做「区服 / 角色名 / 角色列表」的用途（助手就是拿它做导入时的选角色表）。

## 协议要点（要移植到别的语言时看这里）

1. **凭据**：`.bin` 文件**原样** POST 到对应端点，`Content-Type: application/octet-stream`。
2. **端点**（带 `_seq` 查询参数，取值与助手一致）：
   - `POST https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1` → `{ roleToken, roleId }`
   - `POST https://xxz-xyzw.hortorgames.com/login/serverlist?_seq=3` → `{ areaList, serverList, roleCount, recommendId, roles }`
3. **响应体是 BON**（不是 JSON、也不是纯 protobuf）：`bon.decode` 出来是普通对象。
   HTTP 响应**没有加密信封**（首字节直接是 BON 的 tag，如 `0x08`）。
4. **WSS URL**：`wss://xxz-xyzw.hortorgames.com/agent?p=<urlencode(token)>&e=x&lang=chinese`，
   其中 `token = JSON.stringify({ ...authuser.data, sessId, connId, isRestore: 0 })`
   （`sessId = Date.now()*100 + rand(100)`，`connId = Date.now() + rand(10)`）。
5. **帧格式**：`bon.encode(msg)` 之后套 **`x` 方案**加密（收发都是，首两字节 `px`）：
   ```
   encrypt: 4 字节随机头 + 明文，整体与随机字节 r(2..249) 逐字节 XOR，
            再令 [0]=0x70 [1]=0x78，并把 r 的 8 个 bit 塞进 [2][3] 的
            第 6/4/2/0 位（先与 0b10101010 清位）
   decrypt: 从 [2][3] 反解出 r → 从下标 4 起 XOR 回去 → 丢弃前 4 字节
   ```
   即：**单字节 XOR + 藏在头里的密钥**，没有真正的密码学强度，移植成本极低。
   （另两套 `lx`（lz4+掩码，`pl`）与 `xtm`（`pt`，依赖 XXTEA）在本路径上没遇到。）
6. **报文五段**：`{ cmd, ack, seq, time, body }`，`body` 是**内层再 BON 编码**的字节串。
   连上后第一条就是 `cmd: "role_getroleinfo"`，body 默认字段：
   `{ clientVersion: "2.10.3-f10a39eaa0c409f4-wx", inviteUid: 0, platform: "hortor", platformExt: "mix", scene: "" }`。
   响应 `cmd: "role_getroleinforesp"`，`body = { role: {...139 个字段}, serverViewId }`。
7. **BON 编码**（`bonProtocol.js` 的 `BonEncoder`/`BonDecoder`）：tag 字节 =
   `0` null / `1` int32 / `2` int64 / `3` float32 / `4` float64 / `5` string(UTF) /
   `6` bool / `7` binary / `8` map(object) / `9` array / `10` datetime / `99` stringRef；
   长度与 stringRef 索引用 **7bit varint**；**收发两侧共享一张字符串表**
   （重复字符串改写引用，所以解码器必须按出现顺序建表）。

## ⚠️ 使用前的两条硬约束

1. **不要对正在运行的账号做这件事。** 这会建立**第二个游戏会话**，
   很可能把大厅里那个实例顶掉。宿主侧必须先判断「该账号当前没有运行实例」再拉。
2. 每个账号都要发一次 authuser + 建一条 WSS，**按顺序做、加间隔**，
   别把 30 多个账号一股脑并发出去。

## 复现

```bash
sh setup.sh                                  # 现拷 bonProtocol.js + 软链 node_modules
node probe-roleinfo.mjs  '15小惜.bin'         # WSS 取资料（注意上面两条约束）
node probe-authuser.mjs  '11不不.bin'         # 只看 authuser 返回结构
node probe-serverlist.mjs '11不不.bin'        # 看 serverlist 的 role 列表字段
```

依赖：托管 Node（`~/.workbuddy/binaries/node`）+ 工作区里的 `lz4js`。

---

## 选服 / 换角色专题（2026-09-17 新增）

结论与方案见仓库根 `BIN登录认证优化方案.md`。这里只列工具与**必须记住的两条**：

```bash
NODE_PATH=/Users/gg/.workbuddy/binaries/node/workspace/node_modules \
/Users/gg/.workbuddy/binaries/node/versions/22.22.2-2/bin/node <脚本>
```

| 脚本 | 用途 |
|---|---|
| `dump-bin.mjs <bin>…` | 解出 `.bin` 明文（`pl`/`lx` = LZ4 + 头掩码）→ `{platform, platformExt, info, serverId, scene, referrerInfo}` |
| `probe-relogin.mjs <bin>` | 批量改 `serverId` 打 authuser。**用来演示下面第 1 条坑** |
| `probe-pick-role.mjs <bin> <serverId>…` | ⭐ 改 bin 的 `serverId` 重编码 → authuser → WSS 取角色，与 serverlist 逐字段对照 |
| `probe-header-variants.mjs <bin> <serverId>` | body 编码（`lx`/`x`）× `O4e-Encoding` 头 的 4 种组合 |
| `probe-lx-variants.mjs <bin> <serverId>` | ⭐ **服务端会校验 LZ4 帧头校验和**：真压缩帧 / 只存不压+抄来的 HC / 只存不压+HC=0 三向对照 |
| `probe-switch-server.mjs <bin> <serverId>…` | 反面教材：手搓"游戏式参数体"会拿到空角色 |
| `probe-auth-compare.mjs <bin> <serverId>` | SDK 式（body=.bin）vs 游戏式（body=BON 参数）逐字段对照 |
| `probe-deviceid.mjs <bin> <serverId>` | `deviceUniqueId` 取值 / `info` 形态的影响 |
| `probe-o4e-token.mjs <bin> <serverId>` | 补 `O4e-Token` / `O4e-Version` 头有没有用 |

### ⚠️ 三条反直觉的坑（都踩过）

1. **`/login/authuser` 响应里的 `roleId` 是账号 uid，与区服无关**（同一个账号恒为同一个值）。
   拿它判"换服有没有生效"会得到"服务端忽略 serverId"的完全错误结论。
   判据只能是 **WSS `role_getroleinfo` 的 `role.name` / `role.roleId`**。
2. **换服的正解是改 bin 明文里的 `serverId` 再重新编码**（`lx` 或 `x` 都行）。
   千万不要去手搓"游戏式参数体"——`serverViewId` 会跟着 `serverId` 走，但角色是空的
   （`name=111`、`levelId=1`、`gold=10`、uid 变成另一个），缺的是 SDK 会话上下文。
3. **响应编码跟随请求的 `O4e-Encoding`**，而且**服务端校验 LZ4 帧头校验和**：
   - 发 `O4e-Encoding: lx` → 收回 `70 6c` 包着的 BON；不发 → 收回裸 BON（首字节 `08`）。
   - 「`x` body + `lx` 头」会被拒；「只存不压的 LZ4 帧 + HC 写 0」也会被拒
     （`error=指令解析错误`，HTTP 200 但没 roleToken）。
   所以宿主自己造 `lx` 载荷时，HC 必须用 XXH32 真算——见 `probe-lx-variants.mjs`。

