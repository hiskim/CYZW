#!/bin/sh
# 账号卡「第三行」宽度核算探针。
#
# 为什么需要它：侧栏文字列只有 130pt 上下，而「等级 / 战力」要跟分组名抢这一行。
# 凭感觉改字号/缩写很容易改出「显示成 Lv9090…」这种半截数字，而且只有在**具体某个
# 账号**（位数够长、或分组名够长）上才暴露。这里是可复算的算式 + 真实字体测量。
#
# 用法：sh LobbyCoreSystem/Scripts/stats-width-probe.sh
#
# 它做两件事：
#   1) 从 AccountSidebarView.swift 里**抽取真的** abridgedPower / exactStatsHelp
#      （不是抄一份，避免与产品代码漂移）；
#   2) 用真实字体（10pt monospacedDigit）量出四档退让各自的像素宽度，
#      再对照文字列可用宽度，报出每种「账号 + 分组名长度」组合会命中哪一档。
# 判据：任何组合都不允许走到「⑤不显示」或「④仅战力」——即不许丢信息、不许截断。
set -e

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/LobbyCoreSystem/Sources/LobbyUI/AccountSidebarView.swift"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$SRC" "$WORK/Extracted.swift" <<'PY'
import re, sys
src_path, out_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding='utf-8').read()
funcs = []
for name in ('abridgedPower', 'exactStatsHelp'):
    m = re.search(r'    private static func ' + name + r'\(.*?\n    \}\n', src, re.S)
    if not m:
        sys.exit('抽取失败：AccountSidebarView.swift 里找不到 ' + name + '（被改名或挪走了？）')
    funcs.append(m.group(0))
body = '\n'.join(funcs).replace('private static func', 'static func')
open(out_path, 'w', encoding='utf-8').write('import Foundation\n\nenum Extracted {\n' + body + '}\n')
PY

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit
import Foundation

// ⚠️ 尺寸常量必须与源码一致（改了内边距 / 按钮 / 间距 / 行内元素就同步改这里）：
//    LobbyRootView.sidebarWidth、AccountSidebarView 的 padding 与 HStack(spacing:)
// 行内**没有**常驻状态胶囊（「运行中」已删），所以可用宽度与运行态无关。
// 将来若又在行内加常驻元素（胶囊 / 角标 / 徽标），务必在这里减掉它的宽度。
let sidebar: Double = 304, sidePadding: Double = 32, cardPadding: Double = 20
let avatar: Double = 28, button: Double = 24, gap: Double = 9, spacerMin: Double = 6
let lineSpacing: Double = 4          // 第三行 HStack(spacing: 4)
let textColumn: Double = sidebar - sidePadding - cardPadding
    - avatar - gap * 4.0 - button - button - spacerMin

let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
let labelFont = NSFont.systemFont(ofSize: 10)
func w(_ s: String, _ font: NSFont = digitFont) -> Double {
    Double((s as NSString).size(withAttributes: [.font: font]).width)
}

print(String(format: "文字列总宽：%.0fpt", textColumn))
print("")

// 分组名长度不可控（用户可以建任意长的名字），所以它是这里唯一的挤压来源。
let groupLabels = [
    ("未分组 / 按该组筛选（不显示）", ""),
    ("短分组名「主力」", "主力"),
    ("长分组名「主力搬砖大号」", "主力搬砖大号"),
]

let accounts: [(String, Int, Int)] = [
    ("4 位等级 + 十亿战力", 9090, 2_181_261_311),
    ("4 位等级 + 十亿战力", 8708, 1_266_220_000),
    ("3 位等级 + 十亿战力", 750, 12_662_220_81),
    ("3 位等级 + 万档战力", 120, 52_533_888),
    ("千亿战力", 1, 123_456_789_000),
    ("小号", 15, 77885),
    ("只有等级（战力缺失）", 300, 0),
]

func pick(_ avail: Double, _ level: Int, _ power: Int) -> (String, Bool) {
    let p = Extracted.abridgedPower(power)
    let lv = "Lv\(level)"
    let full = "\(lv) · \(p)", tight = "\(lv)·\(p)"
    let stacked = max(w(lv), w(p))
    if w(full) <= avail { return ("① 完整一行 \(String(format: "%.0f", w(full)))pt", true) }
    if w(tight) <= avail { return ("② 去空格 \(String(format: "%.0f", w(tight)))pt", true) }
    if stacked <= avail { return ("③ 竖排两行 \(String(format: "%.0f", stacked))pt", true) }
    if w(p) <= avail { return ("④ 仅战力 \(String(format: "%.0f", w(p)))pt", false) }
    return ("⑤ 不显示", false)
}

var problems = 0
for (lab, label) in groupLabels {
    var labelWidth = 0.0
    if !label.isEmpty { labelWidth = w(label, labelFont) + lineSpacing }
    let avail = textColumn - labelWidth
    print("分组名：\(lab)  →  给数值留 \(String(format: "%.0f", avail))pt")
    for (name, level, power) in accounts {
        let (pickName, ok) = pick(avail, level, power)
        print("   \(name) → \(pickName)\(ok ? "" : "   ⚠️")")
        if !ok { problems += 1 }
    }
    print("")
}
print("问题档位数：\(problems)")
exit(problems == 0 ? 0 : 1)
SWIFT

xcrun swiftc -O -o "$WORK/probe" "$WORK/Extracted.swift" "$WORK/main.swift" -framework AppKit
"$WORK/probe"
