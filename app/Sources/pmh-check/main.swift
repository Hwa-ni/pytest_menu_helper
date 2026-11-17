import Foundation
import PMHCore

// 사용법: pmh-check <python 경로>...   (각 환경을 검사해 표로 출력. 앱과 같은 PMHCore를 쓴다)
let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    print("사용법: pmh-check <python 경로>...")
    exit(2)
}
let repo = ProcessInfo.processInfo.environment["PMH_REPO_PATH"]
let checker = EnvironmentChecker(repoPath: repo)
for path in args {
    let r = checker.check(pythonPath: path)
    let v = r.pythonVersionText ?? "-"
    let pytest = r.report?.pytestVersion ?? "-"
    let fastapi = r.report?.fastapiVersion ?? "-"
    let plugin = r.report.map { $0.pluginInstalled ? "있음" : "없음" } ?? "-"
    print("\(path)")
    print("  상태: \(r.status.label) | Python \(v) | pytest \(pytest) | FastAPI \(fastapi) | 플러그인 \(plugin)")
    for i in r.issues {
        print("  - [\(i.code.rawValue)/\(i.severity.label)] \(i.message)")
        if let c = i.fixCommand { print("      명령: \(c)") }
    }
}
