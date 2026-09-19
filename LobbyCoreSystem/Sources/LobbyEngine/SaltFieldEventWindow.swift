import Foundation

// MARK: - 盐场开放时段（时间模型）
//
// ⚠️ 这是一个**纯时间模型**，不是 UI 窗口 —— 界面窗口在 `SaltFieldChartWindow.swift`。
//    名字里的 Window 指「场次时间窗」，取自游戏自己的叫法（`__XYZW_SALT_WINDOW__`）。
//
// 为什么宿主必须自己算：盐场图**全时段可打开**（用户要求：常开当装饰、好看），
// 但**取数只能在开赛时段**——非时段内轮询 `war_enterbattlefield` 只会得到空战场，
// 既浪费帧又污染状态（表现是「窗口开着、一直显示 0 据点」，比关着还难判断）。
// 时段口径必须与页面侧一致，所以这份实现逐行对齐权威脚本
// `assets/game/salt-vision-gate.js` 的 `getSaltWindowState` / `fourthSaltSunday`：
//
//   · 周六            19:55:00 – 21:01:00
//   · 当月第 4 个周六之后那个周日   19:55:00 – 21:31:00
//   · 其余时间关闭；`nextTransitionAt` 指向下一个开/关边界
//
// 判「第 4 个周六」的算法有一处容易写错、必须照抄：先取**周日的前一天（周六）**，
// 再看它是不是**那个周六所在月份**的第 4 个周六 —— 不是「周日所在月份」。
// 例：2026-03-01（周日）→ 前一天 2026-02-28 是 2 月的第 4 个周六 → 命中；
//     若按「3 月的第 4 个周六」算就不会命中。月初月末的场次全靠这条。
//
// 时区/DST 一律走 `Calendar.current`（与页面 `new Date()` 的本地时间语义一致）。
public struct SaltFieldEventWindow: Sendable, Equatable {
    /// 当前是否在开赛时段内。
    public let isOpen: Bool
    /// 场次标识 `"Y-M-D"`（**不补零**，与页面 `windowId` 完全一致，便于跨端对日志）；
    /// 非场次日为空串。
    public let windowID: String
    /// 本场开始 / 结束（非开赛日 / 未到点时为 nil）。
    public let startsAt: Date?
    public let endsAt: Date?
    /// 下一个状态翻转时刻：开着 → 结束时刻；没开 → 下一次开始时刻。
    public let nextTransitionAt: Date

    /// 距下一次翻转的秒数（永远 >= 0；窗口文案用）。
    public func secondsToTransition(from now: Date = Date()) -> TimeInterval {
        max(0, nextTransitionAt.timeIntervalSince(now))
    }

    /// 一行状态文案：`开赛中 · 20:12 结束（剩 49 分）` / `未开始 · 今天 19:55 开赛`。
    public func statusText(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        let sameDay = calendar.isDate(nextTransitionAt, inSameDayAs: now)
        formatter.dateFormat = sameDay ? "HH:mm" : "M月d日 HH:mm"

        let remaining = secondsToTransition(from: now)
        let minutes = Int(remaining / 60)
        let tail = remaining > 0
            ? (minutes >= 60 ? "剩 \(minutes / 60) 小时 \(minutes % 60) 分" : "剩 \(max(1, minutes)) 分")
            : "即将翻转"

        let stamp = formatter.string(from: nextTransitionAt)
        if isOpen {
            return "开赛中 · \(stamp) 结束（\(tail)）"
        }
        if let start = startsAt, start > now {
            return "本场未开始 · \(stamp) 开赛（\(tail)）"
        }
        return "非盐场时段 · 下次 \(stamp) 开赛（\(tail)）"
    }
}

// MARK: - 时段判定

public extension SaltFieldEventWindow {
    /// 计算某一时刻的盐场时段状态（默认现在）。
    ///
    /// 与 `salt-vision-gate.js` 的 `getSaltWindowState(date)` 同构：
    ///  1. 当天不是周六 / 第 4 个周六之后的周日 → 关闭，`startsAt/endsAt = nil`，
    ///     `nextTransitionAt` 往后找下一个开赛日；
    ///  2. 是开赛日 → 取当天 19:55 为起点、周六 21:01 / 周日 21:31 为终点；
    ///  3. 起点之前算「没开」，终点之后（同一天内）也算「没开」。
    static func state(at date: Date = Date(), calendar: Calendar = .current) -> SaltFieldEventWindow {
        let weekday = calendar.component(.weekday, from: date)
        let isSaturday = weekday == 7 // Calendar 里 1 = 周日，7 = 周六
        let dayOpen = isSaturday || followsFourthSaturday(date, calendar: calendar)

        guard dayOpen else {
            return SaltFieldEventWindow(isOpen: false, windowID: "",
                                        startsAt: nil, endsAt: nil,
                                        nextTransitionAt: nextStart(after: date, calendar: calendar))
        }

        // 终点：周六 21:01、周日 21:31（页面 `end.setHours(21, day===6 ? 1 : 31)`）。
        let start = clock(date, hour: 19, minute: 55, calendar: calendar)
        let end = clock(date, hour: 21, minute: isSaturday ? 1 : 31, calendar: calendar)
        let open = start.map { date >= $0 } == true && end.map { date < $0 } == true

        let identifier = identifierString(for: date, calendar: calendar)
        let transition: Date
        if open, let end {
            transition = end
        } else if let start, date < start {
            transition = start
        } else {
            transition = nextStart(after: date, calendar: calendar)
        }
        return SaltFieldEventWindow(isOpen: open, windowID: identifier,
                                    startsAt: start, endsAt: end,
                                    nextTransitionAt: transition)
    }

    /// 当前是否处于开赛时段（调用方只需布尔值时的便捷入口）。
    static func isOpen(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        state(at: date, calendar: calendar).isOpen
    }

    /// `fourthSaltSunday`：该日是周日，且它的**前一天**（周六）是其所在月的第 4 个周六。
    ///
    /// ⚠️ 月份的归属看的是那个**周六**（页面里 `saturday.getMonth()`），不是周日自己。
    static func followsFourthSaturday(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.weekday, from: date) == 1 else { return false }
        guard let saturday = calendar.date(byAdding: .day, value: -1, to: date) else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: saturday)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return false }

        // 该月的所有周六（JS 里是逐日推进；这里同构，31 次取值代价可忽略）。
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else { return false }
        var saturdays: [Int] = []
        for candidate in dayRange {
            guard let value = calendar.date(from: DateComponents(year: year, month: month,
                                                                 day: candidate)) else { continue }
            if calendar.component(.weekday, from: value) == 7 { saturdays.append(candidate) }
        }
        // 不足 4 个周六时 `saturdays[3]` 在 JS 里是 undefined → 判定为 false。
        guard saturdays.count >= 4 else { return false }
        return saturdays[3] == day
    }

    /// 从 `date` 往后（含次日）找最近一个开赛日的 19:55。
    /// 与页面的 `findNextStart` 一致：最多往后 8 天，都不命中就退化成「+24 小时」。
    static func nextStart(after date: Date, calendar: Calendar = .current) -> Date {
        for offset in 1...8 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let weekday = calendar.component(.weekday, from: candidate)
            guard weekday == 7 || followsFourthSaturday(candidate, calendar: calendar) else { continue }
            if let start = clock(candidate, hour: 19, minute: 55, calendar: calendar) { return start }
        }
        return date.addingTimeInterval(86_400)
    }
}

// MARK: - 小工具

private extension SaltFieldEventWindow {
    /// 取 `date` 当天的某个钟点（秒 / 毫秒清零，与 JS `setHours(h, m, 0, 0)` 同义）。
    static func clock(_ date: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        parts.nanosecond = 0
        return calendar.date(from: parts)
    }

    /// `windowID`：`"2026-9-19"`（**不补零**，照抄页面的模板串）。
    static func identifierString(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
