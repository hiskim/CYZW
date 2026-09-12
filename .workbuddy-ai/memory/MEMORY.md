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
- 卡片内游戏画面本来就贴齐卡片边缘，改利用率时不要去动 cell 内部。

## 协作约定

- 用户只保留源码改动，从 Xcode 自行运行；**不要**刷新仓库里
  `ios/Shell/build/Debug/IOS2-Mac.app` 的构建产物（会把 dylib / Assets.car /
  _CodeSignature 等未跟踪文件带进仓库，旧快照曾因此整包回退）。
- Commit 风格：`type(mac): 一句话摘要` + 空行 + 分点详述根因与修法。
