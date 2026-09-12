# CYZW 项目长期记忆

## 多开矩阵布局（用户明确的设计约束）

- **单实例游戏窗口必须严格保持 9:16**。禁止用横向填充、裁切上下留白、
  或独立缩放宽高比来「提高利用率」——这类方案已被明确否决。
- 提高有效显示面积的唯一手段是**压缩包裹层边距**。当前三层均为 1px：
  - 游戏窗口 ↔ 画布边缘 = 1px
  - 画布 ↔ 大厅窗口边缘 = 1px
- 边距单一真源：`ios/Shell/MacMatrixFit.swift` 的 `MacMatrixCanvasMetrics`
  （`outerHorizontal` / `outerBottom` / `inner`）。
  `MacMultiOpenManagerView.swift` 的 padding 与 `minHeight` 全部引用它，
  改常量即可，**不要就地写死数值**（两处口径不一致会让卡片尺寸算错）。
- 画布贴齐窗口后不要挂外投影（会被窗口边界裁成脏边），1px 渐变描边足够。
- 顶部控制条（`workspaceHeader` 及未来同类）里所有放进 `HStack` 的 `Text`
  **必须** `.lineLimit(1)`，必要时加 `.minimumScaleFactor(0.6~0.8)`。
  否则画布窄时 SwiftUI 会把 Text 拆成单字符一列竖排，把控制条撑到几十 pt
  高，直接吃掉下方 `GeometryReader` 的可用高度（9:16 反推的画幅也跟着缩）。
- 中文 UI 字符串里嵌套引用一律用 `「」` 或弯引号 `""`，**不要**用直引号 `"`——会与外层字符串边界冲突导致 parse 失败。
- 卡片内游戏画面本来就贴齐卡片边缘，改利用率时不要去动 cell 内部。

## 日志约定

- **不要再写裸 `NSLog` / `print`**，一律用 `ios/Shell/MacLog.swift` 的
  `MacLog.error/warn/info/debug/verbose`；等级口径（verbose = 每资源一条的流水）
  写在 `MacLogLevel` 的文档注释里，归类前先看一眼。
- 昂贵的实参（`sha256`、拼大字符串）必须先用 `MacLog.isEnabled(.xxx)` 挡住，
  否则关掉日志只省了打印、没省掉计算。
- 新增 Swift 文件必须手工登记 `ios/Shell/IOS2-Mac.xcodeproj/project.pbxproj`
  （该工程逐个列源文件：PBXBuildFile / PBXFileReference / Shell group / Sources phase），
  否则 Xcode 里不参与编译。
- 校验编译：`xcodebuild -project … -derivedDataPath /tmp/xxx build`
  （不要写进仓库里的 build 目录）。

## 协作约定

- 用户只保留源码改动，从 Xcode 自行运行；**不要**刷新仓库里
  `ios/Shell/build/Debug/IOS2-Mac.app` 的构建产物（会把 dylib / Assets.car /
  _CodeSignature 等未跟踪文件带进仓库，旧快照曾因此整包回退）。
- Commit 风格：`type(mac): 一句话摘要` + 空行 + 分点详述根因与修法。
