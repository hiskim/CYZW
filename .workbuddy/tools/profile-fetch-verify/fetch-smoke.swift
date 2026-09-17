// 端到端冒烟：用**产品代码**（AccountProfileFetcher + BonCodec + XorFrameCipher
// + 真的 LobbyConfiguration）走一遍真实服务端取一次资料。
//
// 用法：./fetch-smoke '15小惜.bin' [期望等级] [期望战力]
// 不传期望值时，自动读 avatars.json（页面内探针抓到的值）与本次结果对拍——
// 这就是「同账号数值对拍」，是判断这条路拿到的数据可不可信的最直接办法。
import Foundation

var failures = 0
func check(_ name: String, _ pass: Bool, _ detail: String = "") {
    if !pass { failures += 1 }
    print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  → " + detail)")
}

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "15小惜.bin"
let path = ("~/Library/Application Support/AccountBins" as NSString).expandingTildeInPath + "/" + name
guard let binData = FileManager.default.contents(atPath: path) else {
    print("读不到 \(path)"); exit(2)
}
print("凭据：\(name)（\(binData.count) 字节）")

// 已知值（页面内探针抓到的）——同名账号能自动对上就带上期望值
var expectedLevel: Int?
var expectedPower: Int?
let avatarsPath = ("~/Library/Application Support/GameLobby/avatars.json" as NSString).expandingTildeInPath
if let data = FileManager.default.contents(atPath: avatarsPath),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let profiles = root["profiles"] as? [String: Any],
   let known = profiles[name] as? [String: Any] {
    expectedLevel = known["level"] as? Int
    expectedPower = known["power"] as? Int
    print("avatars.json 已知值：level=\(expectedLevel.map(String.init) ?? "-") "
          + "power=\(expectedPower.map(String.init) ?? "-")")
}
if CommandLine.arguments.count > 3 {
    expectedLevel = Int(CommandLine.arguments[2])
    expectedPower = Int(CommandLine.arguments[3])
}
print("")

let fetcher = AccountProfileFetcher()
let started = Date()
let semaphore = DispatchSemaphore(value: 0)
var snapshot: AccountProfileSnapshot?
var failure: Error?
Task {
    do { snapshot = try await fetcher.fetch(binData: binData) }
    catch { failure = error }
    semaphore.signal()
}
semaphore.wait()
let elapsed = Int(Date().timeIntervalSince(started) * 1000)

if let failure {
    check("fetch 成功", false, String(describing: failure))
} else if let snapshot {
    check("fetch 成功", true, "\(elapsed)ms")
    print("   name    = \(snapshot.name)")
    print("   level   = \(snapshot.level)")
    print("   power   = \(snapshot.power)")
    print("   vip     = \(snapshot.vip)")
    print("   headImg = \(snapshot.headImg)")
    check("headImg 是 http(s)",
          snapshot.headImg.hasPrefix("https://") || snapshot.headImg.hasPrefix("http://"))
    check("name 非空", !snapshot.name.isEmpty)
    check("level > 0", snapshot.level > 0)
    check("power > 0", snapshot.power > 0)
    if let expectedLevel {
        check("level 与已知值一致（\(expectedLevel)）", snapshot.level == expectedLevel,
              "本实现 \(snapshot.level)")
    }
    if let expectedPower {
        check("power 与已知值一致（\(expectedPower)）", snapshot.power == expectedPower,
              "本实现 \(snapshot.power)")
    }
} else {
    check("fetch 有结果", false, "既没结果也没错误")
}
print("\n\(failures == 0 ? "全部通过" : "\(failures) 项失败")")
exit(failures == 0 ? 0 : 1)
