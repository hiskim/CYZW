# CYZW 项目长期备忘（ios/Shell · macOS SwiftUI 游戏多开大厅）

## 技术基线
- macOS 大厅：SwiftUI + hiddenTitleBar 玻璃窗，工程 `ios/Shell/IOS2-Mac.xcodeproj`（scheme IOS2-Mac），部署目标 macOS 26.0。
- 构建/验证：`xcodebuild -project IOS2-Mac.xcodeproj -scheme IOS2-Mac -configuration Debug build`；改 UI 结构必须全量构建或 swiftc -typecheck（-parse 查不出语义错误）。
- 数据层：分组 ID 为 String（含 allID/ungroupedID 伪分组）；账号 .bin 存沙盒 AccountBins（AccountFileManager）；脚本存 IOS2Scripts（ScriptManager）。

## UI 约定（用户反复校准的偏好）
- 毛玻璃：NSVisualEffectView behindWindow 真·壁纸折射（VibrancyBackdrop），氛围光深藏蓝 #020713 系 + 星场/光束作 blur 证据层；压暗/提亮层必须带蓝相位，纯黑纯白会显灰。
- 分节结构：左侧中控台侧栏（账号/脚本/设置三段）+ 右侧恒为多开矩阵；账号与脚本同构（管理 UI 在侧栏内）。
- **macOS 悬停：一律用 AppKit tracking area 版 `hoverHighlight`（HoverHighlightModifier，MacMultiOpenManagerView.swift），禁止新写 onHover + @State 悬停——与点击存在竞态、会吞 mouseDown（表现为按钮要点几次才响应）。**
- macOS 文件选择用 NSOpenPanel（ScriptImporter 模式）；SwiftUI .fileImporter 在深层子视图会静默不弹。
- sheet 内部模式受"入口 + 弹窗内切换"双重控制时用父级 Binding；弹窗尺寸只在 macBody 内定义一处。
- 同文件多次编辑必须串行（外置盘并行 Edit 有竞态/丢失风险），改完 sync 后验证。
