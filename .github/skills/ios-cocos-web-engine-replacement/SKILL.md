---
name: ios-cocos-web-engine-replacement
description: 更换、固化和验证 IOS2 WebKit 多开模式使用的 Cocos Creator 2.4.9 Web JS 引擎，适用于替换 ios2-web-cocos2d.js、排查官方/定制引擎差异或处理 physics.js 与 TypeScript helper 兼容问题。
---

# IOS2 WebKit Cocos JS 引擎替换

## 目标

把经过验证的 Cocos Creator 2.4.9 `web-mobile` JS 引擎沉淀为项目内代码，并保持 WebKit 多开启动链路可重复构建、可登录、可排查。不要让 Xcode 或准备脚本默认依赖开发者机器上的外部 Creator 构建目录。

## 核心约束

1. 项目内 `ios-cocos/cocos-project/src/ios2-web-cocos2d.js` 是 WebKit 模式的默认引擎来源；只有用户显式提供新引擎路径时，才导入替换版本。
2. 不要默认使用 `wechatgame` 编译产物替换 WebKit 引擎。优先使用 Creator 2.4.9 的 `web-mobile/cocos2d-js-min.js`，因为 WeChat 构建包含不同运行环境假设。
3. 不要让脚本默认指向 `/Users/gg/NewProject_1`、旧 renderer fallback 或其他项目外路径。外部路径只能作为一次性导入输入，例如 `IOS2_WEB_ENGINE=/path/to/cocos2d-js-min.js`。
4. 当前游戏 WebKit 路径不需要 `physics.js`；不要重新在 `ios2-web-index.html` 中加载 `physics.js`，也不要把 `ios2-web-physics.js` 作为构建必需品，除非用户明确要求恢复物理模块。
5. 官方 `web-mobile` 引擎可能缺少旧定制引擎暴露的全局 TypeScript helper。远端 launcher 报 `Can't find variable: __extends` 时，在 `ios2-web-boot.js` 启动远端 bundle 前安装兼容 helper，而不是回退到外部引擎路径。
6. 替换引擎后必须确认 `ios2-web-cocos2d.js` 没被 `.gitignore` 忽略，并且 Xcode build phase 把它视为项目输入文件，不要再把它当成外部生成产物覆盖。

## 优先排查位置

先用 `rg` 定位这些文件和锚点：

```sh
rg -n "ios2-web-cocos2d|physics.js|IOS2_WEB_ENGINE|IOS2_WEB_MOBILE_ROOT|NewProject_1|__extends|Prepare WebKit Runtime" ios-cocos
```

重点文件：

- `ios-cocos/cocos-project/src/ios2-web-cocos2d.js`：项目内 WebKit Cocos JS 引擎。
- `ios-cocos/cocos-project/src/ios2-web-boot.js`：WebKit 启动、远端 bundle 解密执行、TypeScript helper 兼容层。
- `ios-cocos/cocos-project/src/ios2-web-index.html`：WebKit 页面入口，当前不加载 `physics.js`。
- `ios-cocos/scripts/prepare_ios2.sh`：手动准备脚本，默认应使用项目内引擎。
- `ios-cocos/scripts/prepare_ios2_xcode.sh`：Xcode build phase 准备脚本，默认应使用项目内引擎。
- `ios-cocos/.gitignore`：不能忽略 `cocos-project/src/ios2-web-cocos2d.js`。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj/project.pbxproj`：`Prepare WebKit Runtime` 的 input/output 路径。

## 替换原则

1. 导入新引擎前，确认候选文件存在、能通过 `node --check`，并尽量确认版本是 Cocos Creator `2.4.9`。
2. 把候选 `web-mobile/cocos2d-js-min.js` 复制到 `ios-cocos/cocos-project/src/ios2-web-cocos2d.js` 后，用 `shasum -a 256` 记录并比较来源与目标哈希。
3. 准备脚本只在 `IOS2_WEB_ENGINE` 非空时复制外部引擎；如果项目内目标文件不存在，应报错并提示设置 `IOS2_WEB_ENGINE` 一次性导入。
4. 保留 WebGL 失败路径的 `typeof wx !== "undefined"` 兼容修补，避免 WKWebView 因缺少微信全局变量掩盖真实渲染错误。
5. 如远端 launcher 加载失败，先看 `[ios2-web] load failed` 附近日志。若是 `__extends`、`__decorate`、`__awaiter` 等缺失，优先补或修 `ios2-web-boot.js` 的 TypeScript helper 兼容层。
6. 不要把登录失败直接归因于引擎。区分原生 JSB 日志与 WebKit 日志：`Initializing V8`、`[ios2][js]` 多半是原生 JSB；`[ios2][web]` 才是 WKWebView 实例日志。

## 验证

完成替换或脚本调整后，从仓库根目录执行：

```sh
node --check ios-cocos/cocos-project/src/ios2-web-boot.js
sh -n ios-cocos/scripts/prepare_ios2.sh
sh -n ios-cocos/scripts/prepare_ios2_xcode.sh
rg -n "/Users/gg/NewProject_1|NewProject_1|IOS2_WEB_MOBILE_ROOT|IOS2_WEB_PHYSICS|physics-min\.js|cocos2d-js-min\.a5841|cocos2d-js-for-preview" ios-cocos -g "!**/build/**" -g "!**/.git/**"
shasum -a 256 ios-cocos/cocos-project/src/ios2-web-cocos2d.js
git diff --check -- ios-cocos/.gitignore ios-cocos/scripts ios-cocos/README.md ios-cocos/cocos-project/src/ios2-web-boot.js ios-cocos/cocos-project/src/ios2-web-index.html ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj/project.pbxproj
```

使用 Xcode 构建：

```sh
xcodebuild -project ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj \
  -scheme IOS2-mobile -sdk iphonesimulator -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -quiet
```

最后必须让用户在 iOS 实机或模拟器重新登录验证。成功标准是 WebKit 实例出现 `[ios2-web] boot revision`、远端 launcher 不再报 `Can't find variable: __extends`，并且账号能进入游戏。
