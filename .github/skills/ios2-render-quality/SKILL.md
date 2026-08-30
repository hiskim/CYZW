---
name: ios2-render-quality
description: 维护 IOS2 Cocos/WebKit 游戏画质等级设置，适用于 FairyGUI 画质滑杆、Cocos 单开与 WebKit 单开/多开画质分流、首页清晰度隔离，以及画质切换后布局或触摸异常排查。
---

# IOS2 游戏画质设置

## 目标

让用户只调整登录后游戏页面的渲染画质，不改变账号管理首页、FairyGUI 文本或顶部菜单的显示密度和坐标。Cocos 单开与 WebKit 单开共用一个画质配置，WebKit 多开使用独立配置。

## 画质契约

1. 画质只有 `low`、`medium`、`high` 三档。Cocos 单开和 WebKit 单开共用 `ios2.renderQuality.single`，默认 `high`；WebKit 多开使用 `ios2.renderQuality.multi`，默认 `medium`。
2. 配置页必须使用 FairyGUI `GSlider` 实现可拖动滑杆。滑杆值映射为 0/1/2 三个离散档位，低、中、高标签与当前值同步。
3. 滑杆的轨道和填充区域使用相同高度；更新填充时调整 `GGraph` 宽度，不要横向缩放带描边的图形，否则会出现低档粗、高档细的视觉问题。
4. 滑杆要提供比可见轨道更大的透明触摸区域，并在拖动时捕获触摸。档位变化应立即持久化，不能只依赖 `TOUCH_END`，避免手指离开控件后高档选择丢失。
5. 画质设置是下一次进入游戏时生效的运行参数。保存失败时不能更新“已保存”状态或错误地推进本地档位缓存。

## 渲染边界

1. 启动阶段必须保持管理首页 Retina 高清显示。禁止在 `AppController.mm` 的 `application:didFinishLaunchingWithOptions:` 或 `main.js` 的 `onStart` 中调用单开降采样逻辑；`main.js` 启动时只保持 `cc.view.enableRetina(true)`。
2. Cocos 单开登录成功后，先隐藏/停用 FairyGUI 和账号管理层，再调用 `IOS2Native.applyRenderQualitySingle`，然后启动游戏。低、中、高对应原生渲染纹理降采样因子 3、2、1。
3. Cocos 退出登录或返回首页时调用 `IOS2Native.resetRenderQualitySingle`，将首页恢复为 1x 显示。不要让管理层在降采样坐标系中创建或重新布局。
4. WebKit 由 `IOS2GameWebView.mm` 将 `qualitySingle`、`qualityMulti` 注入实例配置，再由 `ios2-web-boot.js` 根据 `multiOpen` 选择对应配置。单开建议按设备像素比使用 `low=1x`、`medium<=2x`、`high<=3x`；多开建议限制为 `low=1x`、`medium<=1.5x`、`high<=2x`，避免多个 Retina canvas 造成内存峰值。
5. 不要修改外部符号链接的 Cocos 引擎源码来实现开关。若引擎提供的是单向 `setDevicePixelRatio`，在项目原生桥中处理游戏进入与首页恢复，并避免在同一帧重复初始化渲染纹理。
6. 管理首页已隐藏状态栏并采用贴边布局时，不要再次叠加 iOS safe-area 偏移；否则账号标题、配置入口和顶部菜单会整体下移。

## 优先排查位置

先用以下命令定位画质链路：

```sh
rg -n "renderQuality|qualitySingle|qualityMulti|applyRenderQuality|resetRenderQuality|GSlider|multiOpen|enableRetina|setDevicePixelRatio" \
  ios-cocos/cocos-project/main.js \
  ios-cocos/cocos-project/src \
  ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios
```

重点文件：

- `ios-cocos/cocos-project/src/ios2-config-page.js`：FairyGUI 画质滑杆、档位标签、触摸扩大和持久化。
- `ios-cocos/cocos-project/src/ios2-manager.js`：Cocos 登录成功/退出时的画质生命周期，以及管理层隐藏与恢复。
- `ios-cocos/cocos-project/main.js`：启动首页 Retina 设置；不能在这里启动游戏降采样。
- `ios-cocos/cocos-project/src/ios2-web-boot.js`：WebKit 单开/多开画质选择和 canvas 像素比。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/AppController.mm`：原生画质偏好、Cocos 渲染纹理因子和桥接方法。
- `ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/ios/IOS2GameWebView.mm`：向 WebKit 实例注入单开/多开画质配置。
- `ios-cocos/cocos-project/src/ios2-account-view.js`、`ios2-manager-common.js`：检查顶部菜单是否被重复安全区偏移推低。

## 修改原则

1. 先确认问题发生在账号管理首页、Cocos 游戏页还是 WebKit 游戏页，再修改对应层；不要用全局 `cc.view` 像素比设置解决单一游戏页面的问题。
2. 画质配置键和默认值必须在 FairyGUI、原生桥和 WebKit 注入协议中保持一致；未知值回退到各自默认值。
3. Cocos 模式仍是单实例原生 JSB 路径，WebKit 多开仍是唯一多实例路径。画质修复不能改变登录路由、脚本隔离或管理层触摸屏蔽逻辑。
4. 进入游戏前先停用管理 UI，退出时先恢复渲染纹理，再重建管理层；否则可能出现游戏点击无响应、首页字体模糊或顶部菜单错位。
5. 调整滑杆触摸代码后，检查 `TOUCH_START`、`TOUCH_MOVE`、`TOUCH_END`、`TOUCH_CANCEL` 四条路径，确认拖动不会触发页面点击，也不会因触摸取消丢失已选档位。
6. 不要把“画质设置已保存”误写成“立即改变当前游戏画质”，除非同时实现了当前游戏安全的渲染纹理切换和资源生命周期管理。

## 验证

从仓库根目录执行：

```sh
node --check ios-cocos/cocos-project/main.js
node --check ios-cocos/cocos-project/src/ios2-config-page.js
node --check ios-cocos/cocos-project/src/ios2-manager.js
node --check ios-cocos/cocos-project/src/ios2-account-view.js
node --check ios-cocos/cocos-project/src/ios2-web-boot.js
git diff --check
python3 /Users/gg/.codex/skills/.system/skill-creator/scripts/quick_validate.py .github/skills/ios2-render-quality
```

如果修改了 Objective-C/Objective-C++，条件允许时构建：

```sh
xcodebuild -project ios-cocos/cocos-project/frameworks/runtime-src/proj.ios_mac/IOS2.xcodeproj \
  -scheme IOS2-mobile -configuration Debug -sdk iphoneos build CODE_SIGNING_ALLOWED=NO
```

真机冒烟测试至少覆盖：

1. 首次启动首页为高清，账号标题、字体和顶部工具栏不下移、不模糊。
2. 单开分别选择低、中、高，登录后游戏画质对应变化；退出后首页恢复高清，重复登录不会沿用错误档位。
3. WebKit 单开读取 `ios2.renderQuality.single`；WebKit 2 到 4 开读取 `ios2.renderQuality.multi`，不会把多开高画质改回中画质。
4. 滑杆可以从任意位置拖动，轨道粗细均匀，连续点击或拖动后颜色、档位和持久化值保持正确。
5. Cocos 登录后游戏内点击、切换 bin、退出登录和返回首页均正常；WebKit 多开实例仍能独立加载和退出。

最终报告应说明是否完成 Xcode 构建和真实设备验证；仅完成静态检查时，明确提示用户在真机上复测画质、菜单位置、触摸和多开内存表现。
