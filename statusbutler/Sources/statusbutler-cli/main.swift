import Foundation
import AppKit
import StatusButlerCore

// T-052 CLI 薄壳：statusbutler <verb> [args]（AU-03）
// 动作类动词转发 butler:// 给主 App 执行；status 直接读共享快照文件
let arguments = Array(CommandLine.arguments.dropFirst())
let writer = WidgetSnapshotWriter()

let outcome = CLIEngine.run(
    arguments: arguments,
    snapshotReader: { writer.read() },
    actionExecutor: { command in
        // 动作转发：重建 butler:// URL 交主 App（送达即成功语义）
        var components = URLComponents()
        components.scheme = "butler"
        components.host = command.verb
        if !command.args.isEmpty {
            components.queryItems = command.args.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            return .rejected(reason: "无法转发到主 App")
        }
        return .performed
    }
)

switch outcome {
case .printed(let text):
    var out = text
    if !out.hasSuffix("\n") { out += "\n" }
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
    exit(0)
case .exitCode(let code):
    // 码 2 且带 --json 时输出钉死载荷（AU-04 契约）
    if code == 2 && arguments.contains("--json") {
        FileHandle.standardOutput.write((CLIEngine.appNotRunningJSON + "\n").data(using: .utf8)!)
    }
    exit(code)
}
