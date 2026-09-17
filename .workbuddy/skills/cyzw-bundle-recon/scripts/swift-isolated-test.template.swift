// 隔离测试「依赖工程内模块的 Swift 文件」的骨架（见 SKILL.md §5.3）。
//
// 用法：
//   1) 把被测文件里 `import LobbyXxx` 整行剥掉，另存为 Store.swift（逻辑一字不改）
//   2) 本文件改名 TestMain.swift（**不能叫 main.swift**，会与 @main 冲突）
//   3) xcrun swiftc -O -o run Stubs.swift Store.swift TestMain.swift -framework AppKit && ./run
//
// Stubs.swift 要点：所有被引用符号都要 public —— 它们会出现在被测类型的
// default 参数里，internal 会直接编译失败（"cannot be referenced from a default
// argument value"）。所以本文件把桩与测试放在一起，按需裁剪。

import AppKit
import Foundation

// ── 桩（按被测文件实际引用裁剪；示例是 AccountAvatarStore 用到的三样）──
public enum LobbyLog {
    static func verbose(_ format: String, _ args: Any...) {}
    static func debug(_ format: String, _ args: Any...) { print("[debug] " + format) }
    static func info(_ format: String, _ args: Any...) { print("[info ] " + format) }
    static func warn(_ format: String, _ args: Any...) { print("[warn ] " + format) }
}

public enum LobbyConfiguration {
    public static var lobbySupportDirectory: URL { FileManager.default.temporaryDirectory }
}

public struct AccountProfileSnapshot: Sendable, Equatable {
    public let headImg: String
    public let name: String
    public let power: Int
    public let level: Int
    public let vip: Int
    public var isEmpty: Bool { headImg.isEmpty }
}

@main
struct IsolatedTest {
    static var failures = 0
    static var total = 0

    static func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        total += 1
        if !pass { failures += 1 }
        print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  → " + detail)")
    }

    @MainActor
    static func main() async throws {
        // 临时目录 + defer 清理：别污染真实 Application Support。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolated-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 异步落地（下载等）用轮询 Task.sleep 等，不要固定 sleep 一个magic 数：
        // 慢了会假失败，快了会白等。
        // var result: T?
        // for _ in 0..<40 { try await Task.sleep(nanoseconds: 250_000_000); … if result != nil { break } }

        check("骨架可用", true)
        print("\n\(total - failures)/\(total) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
