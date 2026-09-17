// 把 `BootstrapScriptBuilder.makeScript` 的产物打印出来，供 node 侧在假 window 里跑。
// 这样页面垫片那些「改哪条请求的什么」的分支才能离线验证——否则只能靠开游戏看日志。
//
// 用法：dump-bootstrap [--no-credential] [--encoding lx]
import Foundation

let noCredential = CommandLine.arguments.contains("--no-credential")
let serverIDIndex = CommandLine.arguments.firstIndex(of: "--server-id")
let credentialServerID: Int64? = serverIDIndex.flatMap { index -> Int64? in
    let next = index + 1
    guard next < CommandLine.arguments.count else { return nil }
    return Int64(CommandLine.arguments[next])
}
let encodingIndex = CommandLine.arguments.firstIndex(of: "--encoding")
let encoding = encodingIndex.flatMap { index -> String? in
    let next = index + 1
    guard next < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[next]
}

// 明显的假凭据：断言里靠它认「体被换掉了」。
let credential = Data("CREDENTIAL-MARKER-0123456789".utf8)

let script = BootstrapScriptBuilder.makeScript(configuration: .init(
    instanceID: "test-instance",
    accountName: "测试账号",
    authResponseBase64: Data("AUTH-RESPONSE-MARKER-ABCDEFGH".utf8).base64EncodedString(),
    manifestJSON: "{\"a\":1}",
    frameRate: 60,
    qualityRawValue: "high",
    instanceCount: 1,
    credentialBase64: noCredential ? "" : credential.base64EncodedString(),
    credentialEncoding: noCredential ? nil : (encoding ?? LobbyConfiguration.payloadEncodingLX),
    serverOrigin: LobbyConfiguration.gameServerURL.absoluteString,
    credentialServerID: credentialServerID
))

FileHandle.standardOutput.write(Data(script.utf8))
