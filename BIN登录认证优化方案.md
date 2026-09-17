# macOS Lobby · .bin 登录认证优化方案

> 目标问题：**用 .bin 登录进游戏后，无法在游戏里选其它区服 / 换角色 / 切换账号。**
> 参考实现：`/Users/gg/code/xyzw_web_helper`（助手仓）+ 游戏真实代码（CDN 解密的 bundle）
> + 真机壳 `ios-cocos/.../ios/AppController.mm`。
>
> 全部结论都有实测与文件:行号，可直接复核。文末给出分级方案与逐项改动点。

---

## 0. 结论先行

| # | 结论 | 证据 |
|---|---|---|
| 1 | `.bin` 明文就是**一次登录请求的参数**，里面那个 `serverId` **就是决定落在哪个区服角色的字段** | §2.1 |
| 2 | 宿主现在的登录方式（原样 POST `.bin`）**必然锁死默认角色**，因为服务端用它换不出别的区；但**在 POST 前改写 bin 的 `serverId` 就能精确换到目标区服角色**（5 例中 4 例逐字段命中，见 §4.3） | §4.2 / §4.3 |
| 3 | 游戏**自己**也调同一个端点 `/login/authuser`（换服/回流选区都走它），而宿主的 XHR 垫片**无差别**把它也回答成 SDK 首登的旧字节 → **这是"游戏内选区点了没反应"的直接原因** | §3.1 |
| 4 | 游戏内选区的真正机制是 `localStorage["serverId"]` + 状态机 `SwitchRole`；键名是**裸 `serverId`**，宿主完全可以在 `atDocumentStart` 预置 | §3.2 |
| 5 | 宿主**不要**去手搓"游戏式参数体"打 authuser：实测会拿到一个空角色（`name=111/2`、`levelId=1`、`gold=10`、uid 变成另一个），这条路缺 SDK 会话上下文 | §4.4 |
| 6 | **换服的两条落地路径都已实现并通过端到端验证**（§8）：① 启动前选服 → 派生凭据 = 派生账号；② 游戏内选区 → 宿主当**登录代理**，按游戏请求里的 `serverId` 现算应答 | §8 |

> ⚠️ **本文档 §5 的方案段写于实现之前，其中 P1 的原始写法是错的**（「把垫片改成一次性闸门、放行游戏自己的请求」会让游戏拿不到凭据而登录失败——因为页面里 `login_authuser` 的**唯一**调用方就是游戏自己，HSDK 与 `ios2-web-*.js` 都不碰这个端点）。
> 实际实现的形态、以及实现过程中新发现的两条协议事实，见 **§8 实现记录**。

---

## 1. 现状：宿主现在的登录链路到底做了什么

### 1.1 认证发生在 WebView 创建之前

`LobbyCoreSystem/Sources/LobbyEngine/AccountAuthenticator.swift`

```swift
// :25  查询串必须原样拼接，不能走 appendingPathComponent（`?` 会被转义成 %3F → 404）
guard let url = URL(string: LobbyConfiguration.gameServerURL.absoluteString + "/login/authuser?_seq=1")
...
request.httpMethod = "POST"
request.httpBody = binData                                   // :30  body = .bin 原字节
request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")   // :31
request.setValue("lx", forHTTPHeaderField: "O4e-Encoding")                        // :32
request.setValue("close", forHTTPHeaderField: "Connection")                       // :33
...
return AuthResult(authResponseBase64: data.base64EncodedString(),                 // :47
                  accountID: StableIdentifier.identity(forBinData: binData),      // :48
                  ...)
```

### 1.2 响应字节被"喂"给页面，靠一个 XHR 垫片

`BootstrapScriptBuilder.swift`

```js
// :96   无状态的正则 —— 只要路径含 /login/authuser 就一律接管
this._fake = /\/login\/authuser(?:\?|$)/.test(String(url || ''));

// :100-108  send() 完全不看 body，直接回预认证字节（且 __authBytes() 会把 buffer 缓存起来反复用）
__bridgedXHR.prototype.send = function(body) {
  if (!this._fake) return this._native.send(body);
  var self = this; setTimeout(function() {
    self._status = 200; self._response = __authBytes();
    ...
  }, 0);
};
```

`AccountProfileFetcher.swift:21-22` 的注释也点明了同一件事：
"与 `AccountAuthenticator` 打的是同一个 `/login/authuser`"。

### 1.3 账号身份 = bin 内容哈希

`GameAccount.swift:23` / `LobbyConfiguration.swift:70`：
`accountID = "ios2-" + SHA256(bin)`。
`GameViewportInstance.swift:566-575` 按 `GameStoragePolicy` 给每个账号分配确定性
`WKWebsiteDataStore`（隔离模式 = `lobby-game-store-<accountID>`）。

> **这条设计后来变成了方案 A 的免费红利**：同一个人的不同角色，只要 bin 字节不同，
> 就天然是不同账号 ID、不同 localStorage 存储区、不同 WebView —— 完全隔离，不用改存储层。

---

## 2. 参考实现与协议真相

### 2.1 `.bin` 到底是什么

`.workbuddy/tools/ws-profile-probe/dump-bin.mjs`（本次新增）：

```
===== 11不不.bin   1108 字节   head=706c3667032b566f      ← 70 6c = "pl" → lx 方案
  LZ4 解出 1085 字节，前 8 字节 08060508706c6174
  platform      = "hortor"
  platformExt   = "mix"
  info          = { encryptCombUser = "wd1XL1mWJJslCa/BG7fW2LOd…" }
  serverId      = 14028
  scene         = 0
  referrerInfo  = ""
```

三点关键：

1. **编码是 `lx`**（`70 6c` + 掩码位）＝ **LZ4 压缩 + 头部 XOR 掩码**，不是单纯的 XOR；
2. **明文就是一个 `login_authuser` 的请求参数对象**（`platform / platformExt / info / serverId / scene / referrerInfo`）——
   与游戏侧 `LoginManager._authUser` 组装的参数**同形**；
3. **`serverId` 是区服选择字段**。区服号 = `serverId - 27`，且 `serverId ≥ 1000000 / 2000000`
   表示第 1 / 2 个小号位（助手仓 `src/components/ServerRoleList.vue:86-98`）。
   → `14028 - 27 = 14001服`，与文件名 `14001服-温酒.bin` 完全对上。

`11不不.bin` / `14001服-温酒.bin` / `15小惜.bin` 三个 bin 的 `serverId` 都是 14028，
说明这三个号的当前角色都在 14001 服。

### 2.2 助手仓是怎么做的（这就是"选服"的正解）

`src/views/TokenImport/bin.vue`：

```ts
// :258  上传 bin 后先拉该账号的全区服角色列表
const listStr = await getServerList(userToken);
serverListData.value = Object.values(JSON.parse(listStr)).sort((a,b) => b.power - a.power);  // :262

// :181  addSelectedRole —— 选中某个角色后：
const newData = { ...originalBinData };        // 原 bin 明文（BON decode 得到）
newData.serverId = roleInfo.serverId;          // ★ 只改这一个字段
const newBinBuffer = g_utils.encode(newData);  // 重新编码成新的 bin
const roleToken = await transformToken(newBinBuffer);   // 用它去 POST /login/authuser
```

`src/utils/token.ts` 两个端点（与真机一致）：

```ts
// :102  POST https://xxz-xyzw.hortorgames.com/login/authuser   { params:{_seq:1}, responseType:'arraybuffer' }
// :133  POST https://xxz-xyzw.hortorgames.com/login/serverlist { params:{_seq:3}, responseType:'arraybuffer' }
// 两者 body 都是 .bin 原字节，Content-Type: application/octet-stream，且【不带 O4e-Encoding】
```

`src/components/ServerRoleList.vue` 的展示换算：

```ts
function getServerIdDisplay(row) { let sid = Number(row.serverId);
  if (sid >= 2000000) sid -= 2000000; else if (sid >= 1000000) sid -= 1000000;
  return sid - 27; }                       // 区服号
function getRoleIndexDisplay(row) { ... return 0|1|2; }   // 小号位
```

### 2.3 真机壳（iOS）与助手仓是同一套

`ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm`

```objc
// :608  IOS2Authenticate
NSURL *url = [NSURL URLWithString:@"https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1"];
IOS2StartPOST(url, binData,
              @{ @"Content-Type": @"application/octet-stream",
                 @"O4e-Encoding": @"lx",                       // :623
                 @"Connection": @"close" },
              ^(NSData *data, NSHTTPURLResponse *http, NSError *error) {
    s_ios2AuthReady = YES;
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    IOS2CallJavaScript(@"__ios2BinLoginReady", base64);        // :639 交给页面
});
```

→ **真机壳也没有选区能力**，它和我们的宿主一样是"一份 bin = 一个角色"。
所以这不是我们独有的缺陷，而是**上一代宿主继承下来的架构限制**（`AccountBinStore.swift:11-12`
注明与上一代宿主共用目录）。

### 2.4 游戏自己的登录/选区链路（关键）

用本次新增的 `.workbuddy/tools/cdn-bundle/scan-login-cmds.mjs` 解密全部 CDN bundle 后确认，
命令枚举与 `LoginService` 真身在 **`TEST_REMOTE_MODULE`** bundle 的字符串表里：

```
login_authuser / login_authuserresp / login_serverlist / login_serverlistresp
login_selectserver / login_selectserverresp / login_unfreeze / login_dataversion
login_superauthuser / login_rolequery / login_updateversion / login_manifest
```

launcher 的 HTTP 客户端把 cmd 变成路径（`dec-launcher.js` @142448）：

```js
var n = ++u.seq,
    i = "".concat(e, "/").concat(l.cmd.replace("_","/").toLowerCase(), "?_seq=").concat(n);
```

→ `login_authuser` → `https://xxz-xyzw.hortorgames.com/login/authuser?_seq=<自增>`

**这和宿主垫片拦的是同一个 URL。**

游戏侧 `LoginManager` 模块（`dec-game.js` @6778906）：

```js
// @6784785  k.prototype._authUser
var r = I.LocalStorage.instance;
"" == (i = (i = r.getItem("serverId")) && parseInt(i)) && (i = null);      // ★ 读 localStorage.serverId
...
[4, g.LoginService.authUser({
     platform: t.platformType, oriPlatform: t.oriPlatformType, platformExt: t.platformExt,
     info: JSON.stringify(t.encryptUserInfo),
     serverId: i,                                    // ★ 带上它
     scene: 0, referrerInfo: t.isDev ? o : "", deviceUniqueId: s.deviceUniqueId })]

// @6793923  _selectServer  —— 回流用户的选区入口
n = { ..., serverId: 0, ... };
[2, g.LoginService.selectServer({ authUser: n })]
```

`LocalStorage` 的键格式（`dec-launcher.js` @644912）：

```js
a.prototype.getSaveKey = function(e, t) {
  return t == SaveType.ROLE ? "PREF#" + this.id + "#" + e : e.toString();   // GLOBAL 域 = 裸键名
};
```

→ 游戏读写的就是 **`window.localStorage["serverId"]`**（还有 `uid` / `puid`）——**没有前缀**。

---

## 3. 根因

### 3.1 根因 A：XHR 垫片把游戏自己的换服登录吞掉了（**首要**）

`SelectBigServerDialog.switchServer`（`dec-game.js` @~9626000，模块 @9623001）：

```js
switchServer = function(area, serverData, slotServerId) {
  var o = slotServerId || serverData.id;
  if (T.ROLE.serverID !== o) {
    SHOW_SIMPLE_DIALOG(E.NormalDialog, { content: ..., hook: async function(i) {
      if (i !== WindowCloseState.Yes) return;
      var t = C.LocalStorage.instance;
      t.setItem("serverId", o.toString());                 // ① 写目标区服
      t.setItem("uid", T.ROLE.uid.toString());
      t.setItem("puid", T.ROLE.platformUId);
      U.LoginManager.instance.isManualSwitchRole = true;   // ② 标记手动切换
      if (subRole && MultiRoleModule.instance.getRoleWithServerId(o))
        await MultiRoleModule.instance.switchRole(t.slotIndex, Center, From.Server);  // 小号分支
      else
        S.Game.instance.stateMachine.transition(p.GameState.SwitchRole, From.Server); // ③ 状态机重登
    }});
  }
};
```

③ 之后 `LoginManager.login()` → `_authUser()` → 发 `login_authuser`（HTTP）→ **被垫片命中**
（`BootstrapScriptBuilder.swift:96` 的正则无状态、无次数限制），并且 `send()` 连 body 都不看
（`:100`），`__authBytes()` 还会把首次的字节缓存住（`:78-85`）→
**游戏拿到的永远是开服时那份 `roleToken`，于是每次"切换"都回到原角色。**

> 现象完全吻合用户描述：**列表能刷出来（`login_serverlist` 没被拦），但选了没用**。

### 3.2 根因 B：`localStorage.serverId` 这条通道宿主完全没接

即使修好 A，宿主也还有两个可选杠杆没用上：

* 进游戏前想"预设好区服" —— 只需在 `atDocumentStart` 写 `localStorage["serverId"]`，
  游戏首次 `_authUser` 就会带上它。**宿主现在一个字都不写**（`makeWebView()` 的 5 个脚本里没有）。
* 游戏内选区本身也依赖 `localStorage.serverId`（§3.1 ①）。

### 3.3 根因 C：`.bin` 里的 `serverId` 从没被宿主使用

`AccountAuthenticator` 把 bin 原样 POST（`:30`），而服务端对"SDK 式 bin 请求"的语义是
**返回该账号的默认主角色**——实测把 bin 的 `serverId` 改成该账号名下 17 个角色里的任意一个，
`/login/authuser` 返回的 `roleId` **恒为同一个值**（见 §4.2 的坑）。

### 3.4 附带的静默失败点（都是同一类问题）

| 位置 | 问题 | 触发条件 |
|---|---|---|
| `HSDKResponder.swift:63-66` | `deviceUniqueId` 回的是**账号级** `ios2-<bin sha256>`，而真机是**设备级**稳定 ID | 游戏自己发 authuser 时拿到一个语义错位的设备标识 |
| `HSDKResponder.swift:69-75` | `get-check-switchs` 除 4 个白名单外全回 `0` | 若服务端把 `DisabledSwitchRole` 打开，游戏会走 `restartGame(SwitchAccount)`（`dec-game.js` @15592900），而 `restartGame` 走 `jsb.reflection` → 垫片只放行 HSDK 两个类 → **静默丢弃，点了完全没反应** |
| `BootstrapScriptBuilder.swift:64-76` | 垫片对非 HSDK 的 `IOS2Native.*` 一律 `return null` | `PlatformManager.logout / exitGame / restartGame / saveImage…` 全部落空 |

---

## 4. 实测证据（可复现）

工具都在 `.workbuddy/tools/ws-profile-probe/`（依赖托管 Node + workspace 里的 `lz4js`）。

```bash
cd .workbuddy/tools/ws-profile-probe
export NODE_PATH=/Users/gg/.workbuddy/binaries/node/workspace/node_modules
NODE=/Users/gg/.workbuddy/binaries/node/versions/22.22.2-2/bin/node
```

### 4.1 `.bin` 明文结构

```bash
$NODE dump-bin.mjs '11不不.bin' '14001服-温酒.bin'
# → serverId = 14028（= 14001服），字段 platform/platformExt/info/serverId/scene/referrerInfo
```

### 4.2 ⚠️ 坑：`authuser.roleId` 是**账号 uid**，不是游戏角色 ID

```bash
$NODE probe-relogin.mjs '11不不.bin'
# 原始 authuser roleId = 109823932
# 把 bin.serverId 依次改成 4046/4414/9365/11078/13931/14028/…/2014028（全部 17 个）
# → authuser.roleId 恒为 109823932（"服务端忽略 serverId" 的假象）
```

**真相**：`109823932` 是账号 uid（WSS 侧 `role.uid` 也是它）。
判定换服是否生效**必须看 WSS `role_getroleinfo` 的 `role.name` / `role.roleId`**。
这一条我先踩了一次坑，写在这里避免重犯。

### 4.3 ✅ 正解：改 bin 的 `serverId` + `lx` 重编码 → 原样 POST

```bash
$NODE probe-pick-role.mjs '11不不.bin' 14028 9365 4046 26533 2014028
```

| 目标 serverId | 区服 | serverlist 期望 | 实拿（authuser→WSS） | |
|---|---|---|---|---|
| 14028 | 14001服 | `仙✨不后` / 240652604 | `仙✨不后` / 240652604 / level 9090 / power 7,537,616,288 | ✅ |
| 9365 | 9338服 | `不不` / 120251709 | `不不` / 120251709 / level 1432 / power 3,820,789 | ✅ |
| 4046 | 4019服 | `不不` / 720670918 | （WSS 未在 12s 内回包，非逻辑错误） | ⚠️ |
| 26533 | 26506服 | `开灯整吧姐夫` / 716243732 | `开灯整吧姐夫` / 716243732 / level 8627 / power 10,773,758,569 | ✅ |
| 2014028 | 2014001服 | `神经蛙` / 558905464 | （WSS 未在 12s 内回包） | ⚠️ |

**4 个成功样本的 `roleId` 与 `serverlist` 逐字段一致** → 换服链路成立。

编码/请求头的组合约束（`probe-header-variants.mjs`）：

| body 编码 | `O4e-Encoding` 头 | 结果 |
|---|---|---|
| `lx` 重编码 | 不带 | ✅ |
| `lx` 重编码 | `lx` | ✅ |
| `x` 重编码（助手仓 `g_utils.encode` 的默认） | 不带 | ✅ |
| `x` 重编码 | `lx` | ❌ 无 roleToken |

→ 结论：**头要么与 body 一致，要么干脆不带。宿主现在写死 `O4e-Encoding: lx`**，
一旦改成 `x` 编码就会静默失败（和 `XorFrameCipher.swift` 里那句"猜错比报错难查"同一个道理）。

### 4.4 ❌ 反面教材：别在宿主里手搓"游戏式参数体"

```bash
$NODE probe-switch-server.mjs  '11不不.bin' 9365      # 参数体 + serverId → 9348服 但角色是空的
$NODE probe-auth-compare.mjs   '11不不.bin' 9365      # 对照两条路径
$NODE probe-deviceid.mjs       '11不不.bin' 9365      # deviceUniqueId 取值不影响结果
$NODE probe-o4e-token.mjs '14001服-温酒.bin' 4046     # 补 O4e-Token/O4e-Version 头也没用
```

用 `bon.encode({platform, oriPlatform, platformExt, info, serverId, scene, referrerInfo, deviceUniqueId})`
直接打 host 侧的 `/login/authuser`：

```
serverViewId / serverName 确实跟着 serverId 走（9365→9338服、14028→14001服、4046→4019服）★
但返回的角色是空的：name=111（或 2）、levelId=1、power=0、gold=10、uid 变成另一个（462383162）
补 deviceUniqueId / O4e-Token / O4e-Version 都不改善
```

说明这条路径还缺 SDK 建立起来的会话上下文（设备认证 / info 与 SDK 登录的绑定）。
**结论：不要复刻参数体；改 bin 才是正路**（也正好是助手仓的做法）。

> 副作用核查：两轮实验后 `11不不.bin` 与 `14001服-温酒.bin` 的 `serverlist` 角色数
> **仍是 17 / 原样**，没有新增角色落库。

### 4.5 游戏内选区的入口与开关

| 事实 | 位置 |
|---|---|
| 游戏内入口：设置面板 → 「服务器」→ `SelectBigServerDialog`（`SelMode = SubRoleAdd`） | `dec-game.js` @9697410 |
| 大区列表 / 最近登录 / 搜索 | `ui_selectServer` 包：`SelectBigServerDialog` / `SelectRecentServerDialog` / `SelectServerDialog`（@14238295 起） |
| 转服（`RoleService.shift`）与转服权限检查（`checkShiftAccess`） | `SelectServerModule.sendShift` / `sendCheckShiftAccessResp`（@9664509） |
| 切换账号走 `restartGame(SwitchAccount)` 的条件 | `C_SwitchId.DisabledSwitchRole`，@15592900 |

---

## 5. 优化方案

分四档，按"风险从低到高、价值从高到低"排序。**建议 P0 先做**。

### P0 · 宿主侧"启动前选服/选角色"（已验证可行，不改游戏、不动协议猜测）

**思路**：把 `.bin` 当成模板，**每个角色派生一份 bin**。因为账号 ID = bin 内容的 SHA256，
派生物天然是独立账号 —— 实例、`websiteDataStore`、localStorage、头像、分组全部自动隔离，
**不需要改存储层一行代码**。

#### 改动点

1. **`LobbyEngine/Lz4Block.swift`（新增，约 70 行）** —— 唯一的硬缺口。
   `XorFrameCipher.swift:19-22` 目前明确 `unsupportedScheme("pl（lx / lz4 方案）")`。
   需要 LZ4 **块**格式解压（token 高 4 位 literal 长度 / 低 4 位 match 长度 + 小端 2 字节 offset）。
   压缩可以**不做**：重编码改用 `x` 方案（纯 XOR + 4 字节随机头，`XorFrameCipher.swift` 已有），
   实测"x body + 不带 `O4e-Encoding` 头"服务端接受（§4.3）。

2. **`LobbyEngine/BinCredential.swift`（新增）**
   - `decode(Data) throws -> BonValue`：`lx` 解掩码 → 还原 LZ4 magic（`04 22 4D 18`）→ `Lz4Block.decompress` → `Bon.decode`
   - `func withServerID(_ id: Int64) -> BonValue`：只覆盖 `serverId` 字段，**保留字段顺序与 `info` 的原始形态**
     （`info` 有"BON 对象"和"JSON 字符串"两种形态，实测两种 bin 都存在，**不要统一 stringify**）
   - `encode(BonValue) -> Data`：`Bon.encode` → `XorFrameCipher` 的 `x` 加密
   - 幂等哨兵：解不出/字段缺失要**明确报错**，不要猜（沿用 `BonCodec` 的哲学）

3. **`LobbyDomain/LobbyConfiguration.swift`**
   ```swift
   /// `POST /login/serverlist?_seq=3` —— 取该 .bin 名下全部区服角色（服务端契约，与助手仓一致）
   public static let profileServerListPath = "/login/serverlist?_seq=3"
   ```
   并**去掉** `AccountAuthenticator` 里写死的 `O4e-Encoding: lx`（改由请求体自描述），
   或至少在改写 bin 后同步更新该头 —— 否则 §4.3 表格最后一行会静默复现。

4. **`LobbyDomain/GameRole.swift`（新增）**
   ```swift
   public struct GameRole { let serverID: Int64; let roleID: Int64; let name: String
                            var serverNumber: Int64 { ... /* -27 与 1e6/2e6 位 */ }
                            var slotIndex: Int { ... } }
   ```

5. **`LobbyEngine/AccountRoleCatalog.swift`（新增）** —— 复用 `AccountProfileFetcher` 的
   HTTP + `Bon` 解码，`POST /login/serverlist?_seq=3`（body = bin 原字节）→ `[GameRole]`。
   会话约束沿用现有规矩：**串行 + 400ms 间隔 + 跳过运行中的账号**。
   顺带把「区服 + 角色名」补进账号卡（比现在必须跑起游戏才能拿资料快得多）。

6. **`AccountAuthenticator.authenticate(account:manifest:)` 增加 `role: GameRole?`（或 `serverID: Int64?`）**
   在 POST 前：`binData = BinCredential.decode → withServerID → encode`。
   派生 bin 的落盘位置建议 `AccountBins/<原名>#<区服号>-<小号位>.bin`，
   这样 `listAccountFiles()`、账号 ID、头像、分组、备注**全部自动可用**。

7. **`LobbyUI`** —— 账号卡加「选择区服与角色」入口（sheet/菜单）：
   列出 `AccountRoleCatalog` 的结果（区服号 / 角色名 / 战力 / 小号位），选择后写入偏好。
   写入口沿用既有约定：`LobbySessionModel` 是唯一写入口，落盘走 `AccountGroupStore`
   单 JSON 文档加字段（**别新开文件**）。

#### 价值与风险

* **价值**：直接从"一个 bin 一个角色"升级为"一个 bin 一份账号池"，可多开不同区服；
  游戏侧零改动、协议侧零猜测。
* **风险**：低。唯一的新代码是 LZ4 解压（有逐字节对拍的验证手段：
  拿 `dump-bin.mjs` 的输出做参照向量）。
* **验证**：扩 `profile-fetch-verify` 的 `make-vectors.mjs`，加一组「同 bin × 多个 serverId」
  的向量，跑 `run.sh` 逐字节对拍（现有基建已有 BON + 帧信封对拍）。

### P1 · 修掉"游戏内选区无效"（**已实现，但形态与下面这段原始设想不同**）

> ⚠️ 下面这段是最初的设想，**已被实现推翻**：它假设「游戏自己的 authuser 能打通，放行即可」。
> 实测两件事都不成立——① 页面里 `/login/authuser` 的唯一调用方就是游戏自己（放行 = 没人给它凭据）；
> ② 游戏的请求体是**参数**（含它想去的 `serverId`），服务端要的是**凭据**。
> 正确做法是宿主当**登录代理**：把请求体里的 `serverId` 取出来，用凭据现算一份应答回填。
> 见 §8。以下原文保留，作为「为什么不能那样做」的记录。

`BootstrapScriptBuilder.swift:96` 改成**一次性闸门**：

```js
// 只回答 SDK 那一次；游戏自己的换服/回流选区请求必须放行到真实网络
this._fake = !window.__lobbyAuthConsumed && /\/login\/authuser(?:\?|$)/.test(String(url || ''));
if (this._fake) { window.__lobbyAuthConsumed = true; ... }
```

配套（可选，但建议一起）：

* **`atDocumentStart` 预置 `localStorage["serverId"]`**（键名已确认是裸键，§2.4）——
  让"宿主选的区服"与"游戏首次登录"一致。放在 `makeWebView()` 的脚本序列里
  （`GameViewportInstance.swift:469-501`，建议插在 ① 设置还原之后）。
* 请求体解析：垫片可以顺手把 body 里的 `serverId` 用 `postMessage` 报给原生，**只做观测**，
  便于确认游戏真的发了换服请求（诊断串带 `v=`，沿用 `GameEnhancementScript` 的约定）。

⚠️ **必须先在小号上 A/B 验证**：放行后游戏自己的 `login_authuser` 会真打到服务端，
它是否能在我们这套 WebKit 宿主里换出正确角色，取决于 SDK 会话是否已建立。
开启 Safari Web Inspector（`defaults write com.xyzw.gamelobby.macos lobby.debug.webInspector -bool true`，
`GameViewportInstance.swift:515`）即可观察。

> 若 P1 验证通过，**游戏内的选区/选大区/切小号会一次性全部恢复**，因为那本来就是游戏自带功能。
> 届时 P0 的定位是"启动前选好"的体验增强，而不是能力补齐。

### P2 · 把平台层缺失的出口补上（避免"点了没反应"）

`HSDKResponder.swift` 的 action 分发（@46-90）建议补：

| action / 调用 | 建议语义 |
|---|---|
| `get-check-switchs` 的 `DisabledSwitchRole` / `RestartGame` | 明确回 `0`，并**记一条诊断日志**（现在静默回 0，一旦服务端开关变化无人知道） |
| `sdk-get-device-info` 的 `deviceUniqueId` | 拆成两个标识：**设备级**稳定 ID（持久化在 `GameStorage`）+ 账号级 ID 继续走 `ios2-<sha>`。现在两者混用，与真机语义不符 |
| `jsb.reflection` 非 HSDK 类 | 从"静默 `return null`"改为**上报一次诊断**（`PlatformManager.restartGame / logout / exitGame` 都从这里过） |
| 「切换账号」 | 宿主已有换实例能力；建议把游戏侧 `restartGame(SwitchAccount)` 映射为"重启本实例"，否则该按钮永远是死的 |

### P3 · 健壮性收尾

1. 垫片正则加"路径 + 一次性"双条件（现在任何带该路径的请求都会命中）。
2. `AccountAuthenticator` 写死 `_seq=1`，而游戏的 `_seq` 是自增的；垫片按路径匹配更稳。
3. `AccountProfileFetcher.swift:21-22` 的注释已提示两处共用端点，建议把端点常量与
   "编码方案 ↔ 请求头"的对应关系收进 `LobbyConfiguration`，**禁止散落**。
4. `Info.plist` 的 `NSAllowsArbitraryLoads`（第三方脚本 P0，与本议题无关但一直未修）。

---

## 6. 开放问题

1. **游戏自己的 `login_authuser` 在本宿主里能否换出正确角色**（P1 的核心前提）。
   独立脚本复现只拿到空角色（§4.4），但那是在没有 SDK 会话的环境；
   宿主里 SDK 已先登录，结论可能不同 —— **需要一次 A/B**。
2. `role.serverId` 与 `serverName` 的换算在合服区不一定等于 `serverId - 27`
   （实测 `serverId=26533` 的角色 `serverName=29001服`）。展示区服号请以
   `serverlist` 的 `serverId - 27` 为准，别用 `role.serverName` 反推。
3. `deviceUniqueId` 的正确语义（设备级 vs 账号级）在真机上的实际取值未取到样本。

---

## 7. 附：本次新增的工具与文件

| 路径 | 用途 |
|---|---|
| `.workbuddy/tools/ws-profile-probe/dump-bin.mjs` | 解出 `.bin` 明文（`lx` = LZ4 + 掩码） |
| `.workbuddy/tools/ws-profile-probe/probe-relogin.mjs` | 批量改 `serverId` 打 authuser（**演示 `roleId` 是 uid 这个坑**） |
| `.workbuddy/tools/ws-profile-probe/probe-switch-server.mjs` | 游戏式参数体换服（反面教材） |
| `.workbuddy/tools/ws-profile-probe/probe-auth-compare.mjs` | SDK 式 vs 游戏式两条路径逐字段对照 |
| `.workbuddy/tools/ws-profile-probe/probe-deviceid.mjs` | `deviceUniqueId` / `info` 形态的影响 |
| `.workbuddy/tools/ws-profile-probe/probe-o4e-token.mjs` | `O4e-Token` / `O4e-Version` 头的影响 |
| `.workbuddy/tools/ws-profile-probe/probe-header-variants.mjs` | 编码方案 × 请求头的 4 种组合 |
| `.workbuddy/tools/ws-profile-probe/probe-pick-role.mjs` | **最终验证：改 bin 换服能否命中目标角色** |
| `.workbuddy/tools/cdn-bundle/scan-login-cmds.mjs` | 解密全部 CDN bundle 并搜登录/选区命令常量（`DUMP_DIR=` 可导出明文） |

---

# 8. 实现记录（2026-09-17，已落地并通过端到端验证）

## 8.1 实现形态：两条路径，一个共同底座

```
                        ┌─ 启动前选服（P0）─────────────────────────────┐
                        │ 设置里选「区服 + 角色」→ 派生凭据 → 落库成新账号 │
   .bin 凭据 ──解出──> BinCredential                                        │
                        │                                              │
                        └─ 游戏内选区（P1'）───────────────────────────┘
                          游戏发 login_authuser（体里带 serverId）
                            → 垫片把体交给原生
                            → LoginProxy 按 serverId 现算应答
                            → 回填给游戏（选中目标角色）
```

**共同底座**：`BinCredential`（凭据明文 ↔ 字节）——把「换服」化归为「改一个字段再编码」。

### 新增文件

| 文件 | 职责 |
|---|---|
| `LobbyEngine/Lz4Frame.swift` | LZ4 **帧**解压 + 「只存不压」封帧 + XXH32（帧头校验和） |
| `LobbyEngine/BinCredential.swift` | `.bin` 明文解码 / `serverId` 改写 / `lx` 重编码；`GameServerID` 换算 |
| `LobbyEngine/GameEndpointClient.swift` | `POST` 二进制 → 原始响应字节；解决报文外壳 |
| `LobbyEngine/AccountRoleCatalog.swift` | `/login/serverlist` → `[GameRole]`（**纯 HTTP，不建会话**） |
| `LobbyEngine/LoginProxy.swift` | 登录代理：按游戏请求的 `serverId` 现算应答 + 缓存 + 兜底 |
| `LobbyDomain/GameRole.swift` | `GameRole` / `AccountRoleList` / `GameServerID` |
| `LobbyUI/RolePickerSheet.swift` | 选区面板（区服号 / 角色名 / 小号位 / 当前标记 / 生成账号） |

### 改动文件

| 文件 | 改动 |
|---|---|
| `LobbyEngine/BootstrapScriptBuilder.swift` | XHR 垫片由「无状态回缓存字节」改为「上报请求体 → 等原生回填」，带兜底 |
| `LobbyIPC/PageEvent.swift` | 新增 `.loginAuth(requestID:bodyBase64:)` |
| `LobbyEngine/GameViewportInstance.swift` | 装配 `LoginProxy`、处理 `.loginAuth`、回填 `window.__LOBBY_LOGIN__.complete` |
| `LobbyDomain/EngineContracts.swift` | `AuthResult` 加 `binData`；`AccountStoring` 加 `writeBin` |
| `LobbyEngine/AccountAuthenticator.swift` | 编码头**由凭据决定**（原来写死 `lx`）；把凭据带进 `AuthResult` |
| `LobbyEngine/AccountProfileFetcher.swift` | 暴露 `roleInfo(roleToken:roleId:)` 与 `credentials(fromAuthResponse:)`（响应可能带信封） |
| `LobbyStorage/AccountBinStore.swift` | `writeBin(_:preferredName:)`（派生凭据落盘，幂等） |
| `LobbyUI/LobbySessionModel.swift` | 选区状态 + `requestRoles` + `deriveAccount`（唯一写入口） |
| `LobbyUI/AccountSidebarView.swift` | 账号卡右键「选择区服与角色…」+ 选区 sheet |
| `LobbyDomain/LobbyConfiguration.swift` | `/login/serverlist` 端点、编码头常量 |
| `App/Sources/GameLobbyApp.swift` | `buildTag` → `2026-09-17.14` |

### 关键设计取舍

1. **P0 不需要动协议**：派生的凭据就是一份普通 `.bin`。因为账号 ID = 内容 SHA256，
   它天然是独立账号 → 实例 / `WKWebsiteDataStore` / localStorage / 头像 / 分组**全部自动隔离**，
   还能**同时多开不同区服**。原凭据一字不动，随时退回。
2. **代理的失败必须退化为「改造前的行为」**：解析不出 `serverId`、平台不支持、
   15s 未应答 → 一律回预认证字节。代理只能让事情变好，不能变成新故障点。
3. **首登零额外延迟**：请求的 `serverId` 等于凭据自带的那个时直接命中预认证缓存，
   只有真的要换服才多一次 ~300ms 往返。
4. **垫片不再需要「一次性」判定**：`open()` 里那句无状态正则可以原样保留——
   是「谁来回答」变了，不是「拦不拦」变了。

## 8.2 实现过程中新发现的两条协议事实（**都会静默失败**）

### ① 响应编码跟随请求的 `O4e-Encoding`

| 请求头 | 响应首字节 |
|---|---|
| `O4e-Encoding: lx` | `70 6c`（LZ4 + 掩码包着的 BON） |
| 不发这个头 | `08`（裸 BON） |

`AccountProfileFetcher` 从来不发这个头 → 拿裸 BON，所以它一直 `Bon.decode` 没问题；
而宿主发给游戏的响应必须是 `lx`（游戏的 HTTP 客户端把编码写死成 `lx`，拿到裸 BON 会解不开）。

**推论（踩过）**：代理重算时必须也产出 `lx` 载荷——曾经为了省掉 LZ4 压缩器改用 `x` 方案，
结果服务端回了 `error=指令解析错误`：因为不发 `lx` 头就收回裸 BON，而游戏按 `lx` 解。

### ② 服务端**会校验 LZ4 帧头校验和（HC）**

`.workbuddy/tools/ws-profile-probe/probe-lx-variants.mjs` 的三向对照（一次只变一个变量）：

| 变体 | 结果 |
|---|---|
| ① 参考实现 lz4js 的真压缩帧 | ✅ roleToken |
| ② 只存不压帧 + 抄来的 HC | ✅ roleToken（**证明「只存不压」合法**） |
| ③ 只存不压帧 + HC 写 0 | ❌ `error=指令解析错误` |

所以 `Lz4Frame.storeFrame` 里的 HC 必须**真算**（`Lz4Frame.xxh32`，与 lz4js 的 `xxh32.js` 逐位对齐）。
这一条极难猜：HTTP 200、响应长度也正常，只是没有 `roleToken`。

## 8.3 验证（全部可复跑）

```bash
cd /Users/gg/915/CYZW
sh .workbuddy/tools/profile-fetch-verify/run.sh '11不不.bin'      # 5 段全绿
```

| 段 | 内容 | 结果 |
|---|---|---|
| ① | BON 编解码对拍 | 4/4 |
| ② | 帧信封对拍 | 4/4 |
| ③ | 服务端直取资料（真实 HTTP + WSS） | 全绿 |
| ④ | `.bin` 凭据对拍：**明文逐字节一致** + **双向互操作** | 全绿 |
| ⑤ | 区服角色目录（真实服务端） | 全绿 |
| ⑥ | **登录代理端到端** | 全绿 |

⑥ 的关键输出（产品代码，真实服务端 + WSS）：

```
PASS  无请求体 / 本区 / 无法解析的请求体 → 全部原样返回预认证字节
PASS  换服请求 → 现算应答（305 字节，source=derived）
PASS  同一区服第二次请求 → 命中缓存，未重复打网络
PASS  预认证字节 = 本区角色「仙✨不后」（Lv9090）
   换服后 WSS 实拿：name=开灯整吧姐夫 level=8627 power=10773758569
PASS  换服生效：拿到「开灯整吧姐夫」，与目标「26506服 · 开灯整吧姐夫」一致
```

`level=8627 / power=10773758569` 与 node 侧 `probe-pick-role.mjs` 对同一个
`serverId=26533` 的取值**逐字段一致**，两条独立实现互证。

构建：`xcodebuild -project LobbyCoreSystem/GameLobby.xcodeproj -scheme GameLobby … build` → **BUILD SUCCEEDED**。

## 8.4 还没做的

1. **P2（平台层出口）**：`HSDKResponder` 的 `get-check-switchs` 除白名单外静默回 0；
   `deviceUniqueId` 是账号级而非设备级；非 HSDK 的 `jsb.reflection` 静默丢弃
   （游戏内「切换账号」按钮走 `restartGame`，所以点了没反应）。**未改**。
2. **P1 的实时性**：代理每次换服要等一次 HTTP（~300ms），游戏侧表现为多转一会儿圈；
   没有做「预取相邻区服」。
3. **`role.power/level` 的陈旧问题**：`serverlist` 里非当前区服的这两个值是陈旧的
   （实测同一角色：serverlist 报 Lv1 / 107.7 亿，WSS 实拿 Lv8627 / 107.7 亿）。
   选区面板里的战力只是提示，选完由 `refreshProfiles` 走一趟精确取值。
4. 未提交 git。

---

# 9. 追加修复（2026-09-17 16:30）：游戏内「选择大区」是空的

## 9.1 现象

游戏内 `设置 → 服务器` 能打开「选择大区」面板，但**列表是空的**（只有「最近登录」）。
`SelectBigServerDialog.onShow` 里 `numItems = bigServerList.length`，
而 `bigServerList` 只在 `SelectServerModule._parseFirstServerList` 里填 ——
它由 `LoginService.serverList(...)` 的响应决定。所以：**空列表 ⟺ 那次请求没拿到数据。**

## 9.2 根因：`/login/serverlist` 只认「体 = 凭据本身」

游戏侧调用（`SelectServerModule.getServerData`）：

```js
LoginService.serverList({ platform, oriPlatform, platformExt,
                          info: JSON.stringify(PlatformManager.instance.encryptUserInfo),
                          areaId: 0 })
```

**参数体**。而这几个 `/login/*` 端点要的是**凭据本体**。一次一变量的实测
（`.workbuddy/tools/ws-profile-probe/probe-serverlist-params.mjs`）：

| 变体 | HTTP | 响应大小 | area | server | role |
|---|---|---|---|---|---|
| ① 裸 `.bin`（基准） | 200 | 1,444,939 B | 1335 | 26534 | 18 |
| ② 参数体 + `info`(string) | 200 | **105 B** | 0 | 0 | 0 |
| ③ 参数体 + 没有 `info` | 200 | **105 B** | 0 | 0 | 0 |
| ④ 参数体 + `info`(BON 对象) | 200 | **105 B** | 0 | 0 | 0 |
| ⑤ 参数体 + 不带 `O4e-Encoding` | 200 | **110 B** | 0 | 0 | 0 |
| ⑥ 参数体 + `x` 方案编码 | 200 | **110 B** | 0 | 0 | 0 |

→ **参数体在任何形态下都只得到空列表**（`code`/`error` 都是空的，所以游戏侧连报错都没有，
只是列表空着）。也试过补 `_raw`（从上号器 hook 里看到的字段名）——同样 105 B
（`probe-raw-field.mjs`）。

**结论**：这不是宿主的 bug，而是「游戏自己发的那条请求注定拿不到数据」。
任何不干预的宿主都会看到空列表（真机上应该是 SDK 层的调用，不是这条 JS 调用）。

## 9.3 修复：垫片把这类请求的体换成凭据

`BootstrapScriptBuilder` 里给 XHR 垫片加了第三种去向：

| 请求 | 去向 |
|---|---|
| `/login/authuser` | 原生登录代理（按 `serverId` 现算应答） |
| **`/login/serverlist`** | **真 XHR 照常 open（URL / 方法 / `_seq` 全原样），`send` 时把 body 换成凭据本体 + 编码头** |
| 其它 | 原样放行，body 一字不改 |

凭据本体由宿主在引导脚本里注入（`window.__IOS2_GAME_INSTANCE__.credential`，
与 `AccountAuthenticator` 发出去的那份完全同一个字节 + 同一个编码头）。

设计要点：
- **不新增桥流量**：1.44 MB 的响应留在页面自己的网络栈里，不走 base64 中转。
- **凭据缺失就退化**：`credential` 为空（旧宿主 / 别的页面）→ 退回原样放行 = 改造前行为。
- 顺带加了一条诊断：其它未被接管的 `/login/<x>` 请求会打一行
  `[lobby] 未接管的 /login/<x>（体是游戏参数，服务端可能只回空）`，便于下次定位。

## 9.4 验证

新增**离线段**（不需要开游戏，也不需要账号没在运行）：

```bash
cd /Users/gg/915/CYZW
OFFLINE_ONLY=1 sh .workbuddy/tools/profile-fetch-verify/run.sh '11不不.bin'
```

其中「页面引导脚本垫片」一段是把 `BootstrapScriptBuilder.makeScript` 的**真实产物**
（`dump-bootstrap.swift` 打印出来）拿到 node 的假 `window` 里跑，逐条断言：

```
① /login/authuser 交给原生代理，不落到网络          ✅（含上报里带 requestId + 原始 body）
② 原生回填能完成那条挂起的 XHR（readyState=4 / 200）  ✅
③ /login/serverlist 把体换成凭据                     ✅（URL/方法原样、体=凭据、编码头 lx、参数体没发出去）
④ 其它请求原样放行（body 一字不改）                   ✅
⑤ 凭据缺失时退回原样放行                              ✅
```

`OFFLINE_ONLY=1` 会跳过所有 `authuser + WSS` 段落（那些会建游戏会话，**大厅正在跑时必须跳过**，
否则会顶掉正在玩的实例）；纯 HTTP 的 `/login/serverlist` 不建会话，可以照跑。
`buildTag` → `2026-09-17.15`。

---

# 10. 第二轮（2026-09-17 16:45）：「选择大区」仍然空 —— 追加兜底与不可漏的诊断

## 10.1 这一轮排除了什么

| 假设 | 结论 |
|---|---|
| 凭据没注入 | ❌ 日志里 `凭据体 1116 字节，编码头 lx` |
| 凭据的 `serverId` 为 null 导致列不出来 | ❌ 直接实测：`13上仙.bin`（serverId=null）裸 bin → **1335 区 / 26534 服 / 7 角色** |
| 日志等级把诊断吃掉了 | ❌ `lobby.log.level` 未设置 → `integer(forKey:)` 返回 0 → `Level(rawValue: 0)` = **verbose**（不是 `?? .info` 兜底！），所以 `console.log` 是可见的 |
| 事件没走到选区面板 | ❌ 日志里 `ui_selectServer` 包已加载 |

**关键推论**：既然 `console.log` 可见、而我的
`[lobby] /login/serverlist 改用凭据体` 那行没出现，说明**游戏没有发出那条 XHR**。

而「选择大区」的条目其实**不来自服务端**——`SelectServerModule._parseFirstServerList` 里
`bigServerList` 完全由客户端配置 `bigServerConf`（`page === "bigServer"` 那几条）生成，
服务端返回的 `serverList` 只用来给它们挂 `bindServerData`：

```js
"bigServer" === e.page && ( (i = h.get(e.id))
  ? (t.bindServerData = i, …)
  : cc.error("服务器还未开启：" + e.id + " -" + e.serverName) )
…
_.push(t)                       // ← 无论有没有 bindServerData 都 push
bigServerList.push(…)           // ← 所以「条目在、内容是空的」= 服务端数据没到
```

→ 与截图完全吻合：**条目在（那种「胶片格」就是它的样式），内容是空的**。

## 10.2 这一轮做了什么

1. **诊断全部升到 `console.warn`**（并在 `__LOBBY_LOGIN__.stats()` 里计数），
   原生侧在 `didFinish` 后 +15s / +45s / +120s 各捞一次快照（`[login-stats] …`）。
   计数含 `authXHR` / `credentialXHR` / `passthroughLoginXHR` / `serverListHooked` /
   `wsLoginCmds`，一眼能分辨「没发」「走 HTTP 发了」「走 WS 发了」。
2. **WS 嗅探**：包一层 `WebSocket.prototype.send`。帧是 BON + 单字节 XOR（密钥藏在头 4 字节），
   所以对 2..249 逐把钥匙试解前 96 字节，找 `login_xxx` —— 代价可忽略，但能直接回答
   「这条命令到底走哪条通道」。
3. **`serverList` 兜底接管**：不管游戏走 HTTP 还是 WS，都把
   `__require('data-index').LoginService.serverList` 换成「自己用凭据体发 HTTP、自己解码」。
   三条安全线任一不成立就**不接管**（保持原样）：
   没有凭据/origin、找不到 `LoginService`、拿不到 BON 解码器（模块 `13`）。
   解码失败 / 请求失败 → 一律 `resolve(原实现())`。
   ⚠️ 还要补两个字段：`deletedRoles`（游戏自己的响应类会给 `new Map()`，裸 BON 里没有；
   缺了会让 `_parseFirstServerList` **直接抛异常**）与 `maxViewId`（由 `serverList[].viewId` 推）。

## 10.3 离线回归（⑦）

`verify-bootstrap-shim.mjs` 新增第 ⑦ 段：造出 `__require` 的两个模块，断言
「装得上 / 统计里 `serverListHooked=true` / 自己发了请求且 URL 对 / 发的是凭据体 /
返回 `{code:0, getData}` / 补齐了 `deletedRoles`(Map) 与 `maxViewId` / 原实现没被调用」。

⚠️ 顺手修掉一个隐式依赖：兜底里原来写 `new XMLHttpRequest()`（靠裸标识符的全局绑定）。
浏览器里能过，但在别的宿主里会变成 `ReferenceError: XMLHttpRequest is not defined`。
已改成显式 `new window.XMLHttpRequest()` —— 顺带让它在假 window 里可测。

`buildTag` → `2026-09-17.17`。

---

# 11. 第三轮（2026-09-17 16:50）：定位到真正的断点 —— 响应缺两个字段

## 11.1 决定性证据

上一版加的计数在日志里回来了：

```
[login-stats] +15s {"authXHR":1,"credentialXHR":1,"passthroughLoginXHR":2,
                    "serverListHooked":false,"wsLoginCmds":[]}
```

- **`credentialXHR: 1`** → 「换体」那条 XHR **确实发出去了**。所以命令走的就是 HTTP，
  WS 假设可以彻底删掉；搭的那层 WS 嗅探与 `LoginService.serverList` 接管都是走错了方向。
- `wsLoginCmds: []` → 印证。
- `serverListHooked: false` → 那层接管没装上（也就等于没起作用）。

## 11.2 真正的断点：服务端响应里没有解析器要的字段

把 `/login/serverlist` 的真实响应摊开看（`15小惜.bin`，1,450,417 字节）：

| 层 | 字段 |
|---|---|
| 外层报文 | `seq, ack, time, resp, cmd, body` |
| **内层 body** | `areaList, serverList, roleCount, recommendId, roles` |

而游戏侧 `SelectServerModule._parseFirstServerList` 需要 **`deletedRoles`** 与 **`maxViewId`**：

```js
i = e.deletedRoles,                       // undefined
o = (i && 0 < i.size && (…), this.addLocalArea("最近登陆", …)),
r = (…, e.maxViewId);                     // undefined → maxAreaId = NaN
for (var s = 1; s <= r; s++) { … }        // 直接跳过
…
e.deletedRoles.forEach(function (e, t) { … })   // ★ TypeError：整段解析在这里中断
C.BigServerConf.map.forEach(…)                  // ← 永远到不了 → bigServerList 是空的
```

→ `bigServerList` 填不上 = **「选择大区」是空面板**，而且**连一条报错都看不到**
（异常发生在 promise 里，被游戏的 `.then` 链吞掉）。

顺带两个细节：
- `serverList` 在 BON 里是 **数组（tag 9）不是 map**。第一版补丁按 map 遍历 → 一个都取不到
  （服务器 0 个、`maxViewId` 算出 0）。已改。
- `deletedRoles` 必须是 **`Map`**（游戏按 `0 < i.size` / `i.forEach` 用），给普通对象会二次抛异常。

## 11.3 修法：在数据进解析器之前补字段

打 `SelectServerModule.prototype._parseFirstServerList` / `_parseServerList` 两个方法：

```js
if (!data.deletedRoles) data.deletedRoles = new Map();
if (data.maxViewId === undefined) data.maxViewId = 最大 viewId（由 serverList[].viewId 推）;
return original.apply(this, arguments);   // 原样透传，不改变原有行为
```

为什么选这个锚点（而不是去打 `LoginService.serverList` 或自己重新解码响应）：

| | 锚在解析器 | 锚在 serverList / 自己解码 |
|---|---|---|
| BON 解码器 | **不需要**（页面里没有可用的） | 需要 |
| 大包搬运 | **不需要**（数据在页面里自己流转） | 需要把 1.4MB 响应过桥 |
| 依赖 | `SelectServerModule` 是模块表短名（已验证） | `data-index` / 模块 13 都试过，没装上 |
| 失败表现 | 不补 → 和现在一样空（无回归） | 同上 |

「请求体换凭据」那层保持不变 —— 它负责**数据是对的**，这一层负责**数据能被解析**。

## 11.4 顺手修掉一个让排查绕远的 bug

**console 桥原来挂在引导脚本的末尾**，所以引导脚本自己更早的 `console.*` 调用
（凭据注入、通道判断……）**全部落在页面里、回不到宿主**。这直接导致
「日志里没有 = 没发生」这个推论在第一、二轮是错的。
现在桥 **最先安装**，页面侧日志（含所有诊断 warn）都会出现在宿主日志里。

## 11.5 离线回归（⑦ 已改写）

`verify-bootstrap-shim.mjs` 第 ⑦ 段现在**复刻游戏那一行** `data.deletedRoles.forEach(…)`：
补丁没生效就地抛异常、测试红。断言包含「原实现被调用且拿到同一个对象」「返回值原样透传」
「补上 `deletedRoles`(Map)」「补上 `maxViewId`=29501」「原有字段没被动过」「统计记下服务器数」。

`buildTag` → `2026-09-17.18`。

---

# 12. 第四轮（2026-09-17 17:00）：把诊断落盘，不再靠粘贴日志

## 12.1 上一份日志其实说明「补丁挂上了」

```
[lobby-macos] [js] [lobby] 凭据本体已注入：1128 字节，编码头=lx        ← console 桥前移生效
[lobby-macos] [login-stats] +15s {"authXHR":1,"credentialXHR":0,
      "passthroughLoginXHR":2,"serverListHooked":false,"wsLoginCmds":[],
      "parseHooked":true}                                            ← 解析补丁已挂上
```

- **`parseHooked: true`** —— `SelectServerModule` 的解析补丁**确实装上了**。
  （也顺带解释了上一轮 `serverListHooked:false`：`data-index` 那个锚点确实拿不到，
  而 `SelectServerModule` 这个短名拿得到。）
- `credentialXHR: 0` **不是失败**：紧跟着日志里才出现
  `bundle URL rewritten: /remote/ui_selectServer/index.a7ee4.js` ——
  说明 +15s 快照发生在**打开面板之前**，你粘贴的那份日志正好在这里被截断，
  没包含面板打开之后的几十行。所以这一轮无法判定成败。

## 12.2 不再让用户粘日志：诊断落盘

排查依赖「从控制台里挑行粘贴」这件事本身很脆（两次都正好截在关键处之前）。改成落盘：

```
~/Library/Application Support/GameLobby/diagnostics.log
```

落盘内容只挑登录链路的关键行，由 `LobbyStorage/DiagnosticsLog.swift` 维护
（单文件 256KB 上限，超出只留尾部）：

| 来源 | 行 |
|---|---|
| 实例就绪 | `[agent] <账号> 凭据 serverId=… 凭据体 … 字节 编码头 …` |
| 页面（console 桥转发，含 `[lobby]` 的行） | `[js] [lobby] 凭据本体已注入…` / `改用凭据体…` / `完成：status=… 响应 … 字节` / `解析补丁已挂上` / `未接管的 /login/xxx` |
| 登录代理回填 | `[login-proxy] 应答 qN（来源=cached/derived/fallback，N 字节）` |
| 页面计数快照 | `[login-stats] +10s/+25s/+40s/+60s/+90s/+150s {…}` |

快照从 3 个改成 **6 个**（覆盖到 150s），保证「打开面板」这一步一定落在某个快照之后；
并把 `passthroughLoginXHR` 从计数升级为**路径列表**（`passthroughPaths`），
一眼能看出还有哪些 `/login/*` 没被接管。

## 12.3 顺带纠一个语义错误：`recommendId` 不是「凭据区服」

`AccountRoleCatalog` 的冒烟断言原来假定 `recommendId == 凭据自带 serverId`，
这轮它红了：`11不不.bin` 的凭据是 `14028`，而服务端返回 `recommendId=26533`。

原因是 **`recommendId` = 服务端记的「上次登录的区」**，会被历次登录改掉
（我们前面那些 WSS 探针会话就把它改到 26506 服了）。于是：
- 冒烟断言改成「必须指向一个真实角色」，并在输出里注明两者可能不同；
- `GameRole.swift` 的注释写明它**不能**当凭据区服用；
- 选区面板的标签从「当前 / 原账号已在此区」改成 **「上次登录区」**，避免误导。

`buildTag` → `2026-09-17.19`。

---

# 13. 事故与修复（2026-09-17 17:05）：卡在「正在加载游戏场景」是我引入的

## 13.1 症状与定位

`.19` 上游戏**卡在「正在加载游戏场景」**，日志里没有任何报错。落盘的诊断文件
（`DiagnosticsLog`，这一轮刚加上）直接指出了问题：

```
[17:02:47] [agent] 15小惜.bin 凭据 serverId=14028 凭据体 1128 字节 编码头 lx
[17:02:47] [js] [lobby] 凭据本体已注入：1128 字节，编码头=lx
[17:02:57] [login-stats] +10s {"authXHR":0,"credentialXHR":0,"passthroughLoginXHR":5,…}
[17:03:12] [login-stats] +25s {…同上…}
…一直到 +90s 都是 authXHR: 0
```

`authXHR: 0` 说明**游戏根本没发出那次登录请求** —— 它不是卡在登录，是根本没走到登录。

## 13.2 根因：我加的统计字段漏了初始化

`.19` 往 `__loginStats` 里加了 `passthroughPaths`，但**初始化那行没改上**
（源码是折行的，我的单行 `replace` 没匹配到，而且当时没有断言就放过了）。于是：

```js
if (__loginStats.passthroughPaths.indexOf(match[1]) < 0) { … }
//    ↑ undefined.indexOf → TypeError，抛在这句
```

这句在 **`__bridgedXHR.prototype.open()`** 里，也就是垫在游戏**所有 XHR** 的 `open` 上。
`/login/*` 的每一次 `open` 都抛异常 → 游戏加载流程里的 `login_dataversion` 等调用被打断
→ **加载任务停住，页面停在「正在加载游戏场景」，而且没有报错**
（异常发生在游戏的 promise 链里，被吞掉）。`passthroughLoginXHR: 5` 正好是抛之前自增的次数。

## 13.3 修复

1. **补齐初始化**：`passthroughPaths: []`（并顺手把之前同样没改上的
   `serverListHooked` → `parseHooked` 一起理顺）。
2. **`open()` 加固成绝不抛**：
   - 整个函数体包一层 `try/catch`，兜底动作是「清掉分类标记 + 原样放行」；
   - 统计/诊断**再单独一层 `try/catch`** —— 统计出问题不该影响请求分类；
   - 注释写明这条红线：**垫在游戏请求路径上的代码，任何异常都可能变成「静默卡死」**。
3. **新增回归第 ⑧ 段**（这条 bug 本该被它拦住）：
   - `__loginStats` 的 6 个字段必须**全部存在**（正是这次漏掉的那个）；
   - 给 `open`/`send` 喂一串 URL（含 `/login/authuser`、`/login/serverlist`、
     `/login/dataversion`、`/login`、空串、`null`、`undefined`、普通 URL、`ios2-game://`），
     **一个都不许抛**；
   - 未接管的 `/login/*` 要被记进 `passthroughPaths`。
4. **直接校验产物**（这次补上的动作）：把 `makeScript` 的输出 dump 出来，
   断言初始化行里有 `passthroughPaths: []`，并用 `new Function(src)` 过一遍语法。

`buildTag` → `2026-09-17.20`。离线 8 段全绿。

## 13.4 教训（写进 skill）

- **垫在游戏既有调用路径上的垫片（XHR / 原型方法 / 事件）必须异常安全**：
  这些地方抛异常不会变成「功能失效」，而是**静默卡死**——因为调用方通常在 promise 链里。
- **往诊断结构里加字段时，初始化、读取、写入三处要一起改**，并且要有
  「字段必须存在」的断言兜住（这次就是漏了初始化，且没断言）。
- 改完**先 dump 产物脚本看一眼**（初始化行 / 语法），比开游戏试快得多。

---

# 14. 收口（2026-09-17 18:10）：三件收尾

| 问题 | 根因 | 修法 |
|---|---|---|
| 选大区还是空 | 页面 origin 是自定义 scheme，跨源 XHR 的非安全头被 WebKit 丢掉 → `login/serverlist` 没带上 `O4e-Encoding` → 服务端回**裸 BON**（3,879,411 字节 vs 正确的 1,446,832），游戏按 `lx` 解不开 | `login/serverlist` 也交给**宿主代发**（`LoginProxy.serverListResponse`，凭据体 + lx 头），响应经垫片回填 |
| 游戏内切服后，重启原 bin 就登到新区 | 游戏切服会往账号自己的 localStorage 写 `serverId/uid/puid`，localStorage 按 bin 隔离 ⇒ 原 bin 归属被改掉 | 引导脚本在**会话首次加载**时把 `localStorage.serverId` 钉回凭据自带的区（sessionStorage 打标记，只做一次）；本次会话内切服照常生效 |
| 切服后**账号卡**被刷成新区角色 | 资料探针只认「运行中的页面」，切服后页面里的 `ROLE` 是新区角色 | 探针（agent v2）上报 `ROLE.serverID`；`AccountProfileSnapshot` 加 `serverID`；宿主收到资料时若 serverID 与凭据区**不一致则拦下**（账号卡保持原区资料），切回原区自动恢复 |

经验（都写进 skill）：
- **垫在游戏调用路径上的代码必须异常安全** —— 异常在 promise 链里被吞，表现是静默卡死
  而不是报错（.19 的卡死就是统计字段漏初始化导致 `open()` 抛异常）；
- **页面侧诊断不能依赖 console** —— 游戏 boot 后会把 console 整个换掉，
  关键诊断要走专用 postMessage 通道（`__diag` → `PageEvent.loginDiag` → diagnostics.log）；
- 垫片里的全局对象必须**显式** `window.*`（`localStorage` / `sessionStorage` /
  `XMLHttpRequest` 裸写在沙箱/别的宿主里就是 ReferenceError）；
- 离线回归（`profile-fetch-verify/run.sh`，9 段）已经能在不开游戏的情况下把
  垫片行为、协议字节、账号归属全部钉死 —— 本轮 .24→.25 的回归就是它拦下的。

`buildTag` → 2026-09-17.27（用户已复测通过：列表显示 ✓、切服登录 ✓、
原 bin 归属不变 ✓、账号卡不被污染 ✓）。
