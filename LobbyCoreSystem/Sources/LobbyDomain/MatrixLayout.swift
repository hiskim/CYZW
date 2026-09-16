import CoreGraphics
import Foundation

// MARK: - 多开矩阵尺寸求解器（9:16 严格比例 · 一次线性扫描）

/// 画布容器与网格内容之间的固定留白。
/// 「测量到的画布外框」与「真正能放卡片的区域」必须永远同口径，
/// 抽成常量后改任何 padding 只需要同步这一处。
public enum MatrixCanvasMetrics {
    /// 画布容器左右外边距（画布 ↔ 窗口边缘）。
    public static let outerHorizontal: CGFloat = 1
    /// 画布容器底部外边距。
    public static let outerBottom: CGFloat = 1
    /// ScrollView 内容内边距（游戏卡片 ↔ 画布边缘）。
    public static let inner: CGFloat = 1

    /// 外框宽 → 可用宽的差值。
    public static var horizontalInset: CGFloat { (outerHorizontal + inner) * 2 }
    /// 外框高 → 可用高的差值。
    public static var verticalInset: CGFloat { outerBottom + inner * 2 }

    /// 把测量到的画布外框尺寸换算成真正能摆卡片的内容区尺寸。
    public static func contentSize(from frame: CGSize) -> CGSize {
        CGSize(width: max(120, frame.width - horizontalInset),
               height: max(120, frame.height - verticalInset))
    }
}

/// 一次适配的结果。
public struct MatrixLayout: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// 卡片宽度 = 游戏画面宽度（卡片没有左右内边距）。
    public let cardWidth: CGFloat
    /// 卡片顶部控制条高度（随密度分档）。
    public let headerHeight: CGFloat

    /// 游戏画面高度：由宽度严格反推 9:16（高 = 宽 × 16/9）。
    public var gameHeight: CGFloat { cardWidth / MatrixFit.gameAspect }
    /// 卡片总高 = 顶部控制条 + 游戏画面。
    public var cardHeight: CGFloat { gameHeight + headerHeight }
    /// 网格实际占宽（容器内居中用）。
    public var gridWidth: CGFloat {
        MatrixFit.spacing * CGFloat(max(0, columns - 1)) + cardWidth * CGFloat(columns)
    }
    /// 网格实际占高。
    public var gridHeight: CGFloat {
        MatrixFit.spacing * CGFloat(max(0, rows - 1)) + cardHeight * CGFloat(rows)
    }
}

/// 矩阵尺寸求解器：给定实例数 n 与画布可用区域，求「能整屏放下且尽可能大」的
/// 卡片尺寸，同时保证游戏画面严格 9:16。
///
/// ## 模型
/// 卡片 = 固定顶部控制条 + 游戏画面（宽:高 = 9:16）；
/// 网格 = columns 列 × rows 行（rows = ceil(n / columns)），间距 14pt。
///
/// ## 算法（闭式解 + 单调剪枝，微秒级）
/// 对每个候选列数 c：
/// ```
/// rows        = ceil(n / c)
/// wByWidth    = (W - s·(c-1)) / c                       // 宽度分出来的上限
/// wByHeight   = ((H - s·(rows-1)) / rows - header) · 9/16 // 高度分出来的上限
/// cardWidth   = min(wByWidth, wByHeight)                // 两个方向都要塞得下
/// ```
/// 取 cardWidth 最大的 c。`wByWidth` 随 c 严格单调递减，一旦它 ≤ 当前最优即可
/// break——窗口拖拽期间逐帧重算也不会掉帧。
public enum MatrixFit {
    /// 卡片间距。
    public static let spacing: CGFloat = 14
    /// 顶栏高度三档（越密越矮，省下的高度全部还给 9:16 画面）：
    /// 单开 32 → 多开单行 24 → 多开多行 20。
    public static let headerHeightSingle: CGFloat = 32
    public static let headerHeightMulti: CGFloat = 24
    public static let headerHeightDense: CGFloat = 20

    /// 游戏画面宽高比（宽 / 高）。
    public static let gameAspect: CGFloat = 9.0 / 16.0
    /// 卡片宽度下限（再小游戏 UI 没法用）。
    public static let minCardWidth: CGFloat = 96
    /// 卡片宽度上限（防止单实例铺满超大屏导致画布像素过高）。
    public static let maxCardWidth: CGFloat = 720
    /// 浮点安全余量（避免内容正好等于容器高度时冒出 1px 滚动条）。
    public static let safetyMargin: CGFloat = 1
    /// 列数扫描上限。
    public static let maxColumns: Int = 64

    /// 按「实例数 + 行数」取顶栏高度：
    /// 单开 32pt；多开一行 24pt；多开两行及以上 20pt。
    /// 两层条件缺一不可——只看行数的话，双开在宽窗口下是 1 行 × 2 列，触发不了收窄。
    public static func headerHeight(forInstanceCount count: Int, rows: Int) -> CGFloat {
        guard count > 1 else { return headerHeightSingle }
        return rows > 1 ? headerHeightDense : headerHeightMulti
    }

    /// 自动适配：n 个实例在 `container` 内整屏放下的最大卡片尺寸。
    /// - Parameters:
    ///   - count: 实例数量（0 视作 1）。
    ///   - container: 画布**内容区**尺寸（已扣除所有 padding）。
    ///   - forcedColumns: 手动指定列数；nil = 算法挑最优。
    public static func fit(count: Int, in container: CGSize, forcedColumns: Int? = nil) -> MatrixLayout {
        let n = max(1, count)
        let width = max(minCardWidth, container.width - safetyMargin)
        let height = max(headerHeightSingle + minCardWidth / gameAspect, container.height - safetyMargin)

        let columns: Int
        if let forced = forcedColumns {
            columns = max(1, min(forced, maxColumns))
        } else {
            columns = bestColumnCount(count: n, width: width, height: height)
        }
        let rows = (n + columns - 1) / columns
        let header = headerHeight(forInstanceCount: n, rows: rows)
        let cardWidth = clampedCardWidth(columns: columns, rows: rows, width: width, height: height, header: header)
        return MatrixLayout(columns: columns, rows: rows, cardWidth: cardWidth, headerHeight: header)
    }

    /// 手动尺寸：按首选宽度排、列数固定时收缩，结果统一成 MatrixLayout，
    /// 让自动 / 手动两种模式走同一套渲染代码（与上一代口径一致）。
    /// ⚠️ 手动档位同样受**高度约束**：每行可用高度反推出宽度上限（严格 9:16）——
    /// 否则高度满时宽度还能继续加，网格溢出画布、画面变形。
    public static func manual(count: Int,
                              preferredWidth: CGFloat,
                              in container: CGSize,
                              forcedColumns: Int? = nil) -> MatrixLayout {
        let n = max(1, count)
        let width = max(minCardWidth, container.width - safetyMargin)
        let height = max(headerHeightSingle + minCardWidth / gameAspect,
                         container.height - safetyMargin)
        let automaticColumns = max(1, Int((width + spacing) / (preferredWidth + spacing)))
        let columns = max(1, min(forcedColumns ?? automaticColumns, maxColumns))
        let fitted = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = (n + columns - 1) / columns
        let header = headerHeight(forInstanceCount: n, rows: rows)
        // 高度约束：该行数下每行可用高度（扣间距、扣顶栏）能撑起多宽的 9:16 画面。
        let rowHeight = (height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        let widthByHeight = max(0, rowHeight - header) * gameAspect
        let widthCandidate = forcedColumns == nil
            ? min(maxCardWidth, max(minCardWidth, preferredWidth))
            : min(maxCardWidth, max(minCardWidth, min(preferredWidth, fitted)))
        // 两个方向取小：宽度候选与高度上限取小，保证整屏放得下（画面不变形）。
        let cardWidth = min(widthCandidate, max(minCardWidth, widthByHeight))
        return MatrixLayout(columns: columns, rows: rows,
                            cardWidth: cardWidth.rounded(.down), headerHeight: header)
    }

    // MARK: - 内部

    /// 最优列数扫描（单调剪枝，见类型注释）。
    private static func bestColumnCount(count: Int, width: CGFloat, height: CGFloat) -> Int {
        var bestColumns = 1
        var bestWidth: CGFloat = -1
        let cap = max(1, min(count, maxColumns))
        var columns = 1
        while columns <= cap {
            let widthByWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            // 单调剪枝：wByWidth 递减，一旦够不到当前最优，后面全部不可能更优。
            if widthByWidth <= bestWidth { break }
            let rows = (count + columns - 1) / columns
            let header = headerHeight(forInstanceCount: count, rows: rows)
            let widthByHeight = usableGameWidth(rowHeight: (height - spacing * CGFloat(rows - 1)) / CGFloat(rows),
                                                header: header)
            let candidate = min(widthByWidth, widthByHeight)
            if candidate > bestWidth {
                bestWidth = candidate
                bestColumns = columns
            }
            columns += 1
        }
        return bestColumns
    }

    /// 给定列数/行数后反算卡片宽度（两个方向取小，保证整屏放得下）。
    private static func clampedCardWidth(columns: Int, rows: Int, width: CGFloat, height: CGFloat, header: CGFloat) -> CGFloat {
        let widthByWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rowHeight = (height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        let widthByHeight = usableGameWidth(rowHeight: rowHeight, header: header)
        let raw = min(widthByWidth, widthByHeight)
        return min(maxCardWidth, max(minCardWidth, raw.rounded(.down)))
    }

    /// 一行可用高度（扣掉控制条）能撑起多宽的 9:16 画面。
    private static func usableGameWidth(rowHeight: CGFloat, header: CGFloat) -> CGFloat {
        max(0, rowHeight - header) * gameAspect
    }
}
