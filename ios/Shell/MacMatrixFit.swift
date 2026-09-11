#if os(macOS)
import Foundation
import SwiftUI

// MARK: - 矩阵自动适配（9:16 严格比例 · 一次线性扫描）

/// 画布容器与网格内容之间的固定留白（与 MacMultiOpenManagerView 的 padding 一一对应）。
/// 抽取成常量是为了让「测量到的画布外框」与「真正能放卡片的区域」永远同口径。
enum MacMatrixCanvasMetrics {
    /// 画布容器左右外边距
    static let outerHorizontal: CGFloat = 24
    /// 画布容器底部外边距
    static let outerBottom: CGFloat = 20
    /// 画布容器内边距（ScrollView content 的 padding）
    static let inner: CGFloat = 16
    /// 外框宽 → 可用宽的差值
    static var horizontalInset: CGFloat { (outerHorizontal + inner) * 2 }
    /// 外框高 → 可用高的差值
    static var verticalInset: CGFloat { outerBottom + inner * 2 }

    /// 把测量到的画布外框尺寸换算成真正能摆卡片的内容区尺寸。
    static func contentSize(from frame: CGSize) -> CGSize {
        CGSize(width: max(120, frame.width - horizontalInset),
               height: max(120, frame.height - verticalInset))
    }
}

/// 一次适配的结果。
struct MacMatrixLayout {
    let columns: Int
    let rows: Int
    /// 卡片宽度 = 游戏画面宽度（卡片没有左右内边距）
    let cardWidth: CGFloat
    /// 顶部控制条高度（单行 38 / 多行 28，见 MacMatrixFit.headerHeight(forRows:)）
    let headerHeight: CGFloat

    /// 游戏画面高度：由宽度严格反推 9:16（宽:高 = 9:16 → 高 = 宽 × 16/9）。
    var gameHeight: CGFloat { cardWidth / MacMatrixFit.gameAspect }
    /// 卡片总高 = 顶部控制条 + 游戏画面。
    var cardHeight: CGFloat { gameHeight + headerHeight }
    /// 网格实际占宽（用于容器内居中）。
    var gridWidth: CGFloat {
        MacMatrixFit.spacing * CGFloat(max(0, columns - 1)) + cardWidth * CGFloat(columns)
    }
    /// 网格实际占高。
    var gridHeight: CGFloat {
        MacMatrixFit.spacing * CGFloat(max(0, rows - 1)) + cardHeight * CGFloat(rows)
    }
}

/// 多开矩阵尺寸求解器：给定实例数 n 与画布可用区域，求出「能整屏放下、且尽可能大」
/// 的卡片尺寸，同时保证游戏画面严格 9:16。
///
/// ## 模型
/// 卡片 = 固定 38pt 顶部控制条 + 游戏画面（宽:高 = 9:16）。
/// 网格 = columns 列 × rows 行（rows = ceil(n / columns)），间距 14pt。
///
/// ## 算法（闭式解 + 单调剪枝，微秒级）
/// 对每个候选列数 c：
/// ```
/// rows        = ceil(n / c)
/// wByWidth    = (W - s·(c-1)) / c                      // 宽度分出来的上限
/// wByHeight   = ((H - s·(rows-1)) / rows - header) · 9/16   // 高度分出来的上限
/// cardWidth   = min(wByWidth, wByHeight)               // 两个方向都要塞得下
/// ```
/// 取 cardWidth 最大的 c。注意「单一窗口优先最大高度」是这个式子的自然结果：
/// n = 1 时 rows = 1，cardWidth = min(W, (H-header)·9/16)，高度够就用满高度。
///
/// `wByWidth` 随 c 严格单调递减，因此扫描过程中一旦 `wByWidth ≤ 当前最优`，
/// 后面任何更大的 c 都不可能再超过最优（cardWidth ≤ wByWidth），直接 break。
/// 实际迭代次数 ≈ 最优列数量级，没有二分、没有迭代收敛，几十个实例也是常数级开销，
/// 窗口拖拽期间逐帧重算也不会掉帧。
enum MacMatrixFit {
    /// 卡片间距
    static let spacing: CGFloat = 14
    /// 顶栏高度三档（越密越矮，省下的高度全部还给 9:16 画面）：
    /// 单开 32pt → 多开单行 24pt → 多开多行 20pt。
    /// 之所以值得收：卡片宽度是按「行可用高 − 顶栏」反推的，顶栏每减 1pt，
    /// 画面就多 0.5625pt 宽；多开时行数越多，每省 1pt 的收益 × 行数。
    static let headerHeightSingle: CGFloat = 32
    static let headerHeightMulti: CGFloat = 24
    static let headerHeightDense: CGFloat = 20

    /// 向后兼容的默认值（单开档），外部只做兜底用。
    static let headerHeight: CGFloat = headerHeightSingle

    /// 按「实例数 + 行数」取顶栏高度：
    /// 单开 32pt；多开但一行 24pt；多开且排到 2 行及以上 20pt。
    /// 两层条件缺一不可——只看行数的话，双开在宽窗口下是 1 行 × 2 列，永远触发不了收窄。
    static func headerHeight(forInstanceCount count: Int, rows: Int) -> CGFloat {
        guard count > 1 else { return headerHeightSingle }
        return rows > 1 ? headerHeightDense : headerHeightMulti
    }

    /// 游戏画面宽高比（宽 / 高）
    static let gameAspect: CGFloat = 9.0 / 16.0
    /// 卡片宽度下限（再小游戏 UI 就没法用了）
    static let minCardWidth: CGFloat = 96
    /// 卡片宽度上限（防止单实例时铺满超大屏导致画布像素过高）
    static let maxCardWidth: CGFloat = 720
    /// 安全余量：消掉浮点误差，避免内容正好等于容器高度时冒出 1px 滚动条
    static let safetyMargin: CGFloat = 1
    /// 列数扫描上限（再多也没有意义：卡片会小于最小宽度）
    static let maxColumns: Int = 64

    /// 自动适配：n 个实例在 `container` 内整屏放下的最大卡片尺寸。
    /// - Parameters:
    ///   - count: 实例数量（0 视作 1）。
    ///   - container: 画布**内容区**尺寸（已扣除所有 padding）。
    ///   - forcedColumns: 手动指定的列数；nil = 由算法挑最优列数。
    static func fit(count: Int, in container: CGSize, forcedColumns: Int? = nil) -> MacMatrixLayout {
        let n = max(1, count)
        let width = max(minCardWidth, container.width - safetyMargin)
        let height = max(headerHeight + minCardWidth * gameAspect, container.height - safetyMargin)

        let columns: Int
        if let forced = forcedColumns {
            columns = max(1, min(forced, maxColumns))
        } else {
            columns = bestColumnCount(count: n, width: width, height: height)
        }
        let rows = (n + columns - 1) / columns
        let header = headerHeight(forInstanceCount: n, rows: rows)
        let cardWidth = clampedCardWidth(columns: columns, rows: rows, width: width, height: height, header: header)
        return MacMatrixLayout(columns: columns,
                               rows: rows,
                               cardWidth: cardWidth,
                               headerHeight: header)
    }

    /// 手动尺寸：沿用旧的「按首选宽度排、列数固定时收缩」行为，
    /// 只是把结果统一成 MacMatrixLayout，让两种模式走同一套渲染代码。
    static func manual(count: Int,
                       preferredWidth: CGFloat,
                       in container: CGSize,
                       forcedColumns: Int?) -> MacMatrixLayout {
        let n = max(1, count)
        let width = max(minCardWidth, container.width - safetyMargin)
        let automaticColumns = max(1, Int((width + spacing) / (preferredWidth + spacing)))
        let columns = max(1, min(forcedColumns ?? automaticColumns, maxColumns))
        let fitted = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cardWidth = forcedColumns == nil
            ? min(maxCardWidth, max(minCardWidth, preferredWidth))
            : min(maxCardWidth, max(minCardWidth, min(preferredWidth, fitted)))
        let rows = (n + columns - 1) / columns
        let header = headerHeight(forInstanceCount: count, rows: rows)
        return MacMatrixLayout(columns: columns,
                               rows: rows,
                               cardWidth: cardWidth.rounded(.down),
                               headerHeight: header)
    }

    // MARK: - 内部

    /// 最优列数扫描：见类型注释的单调剪枝说明。
    private static func bestColumnCount(count: Int, width: CGFloat, height: CGFloat) -> Int {
        var bestColumns = 1
        var bestWidth: CGFloat = -1
        let cap = max(1, min(count, maxColumns))
        var columns = 1
        while columns <= cap {
            let widthByWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            // 单调剪枝：wByWidth 递减，一旦它够不到当前最优，后面全部不可能更优。
            if widthByWidth <= bestWidth { break }
            let rows = (count + columns - 1) / columns
            // 顶栏按候选行数取档，但 wByWidth 与顶栏无关，上面的单调剪枝依然成立。
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
#endif
