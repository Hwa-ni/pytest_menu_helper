import Foundation

/// 검사 결과 해석(순수 함수). 프로세스·파일에 접근하지 않는다.
public enum Interpreter {
    public static let minPython = [3, 9]
    /// PMH_RUN_ID를 지원하는 첫 플러그인 버전. 이보다 낮으면 앱이 실행 ID를 정할 수 없다.
    public static let minPluginVersion = [0, 2, 0]
    /// 다른 터미널의 실행을 알아보는 필드(pid, invocation_dir, env.prefix, parent_run_id)를 남기는 첫 버전.
    /// 이보다 낮아도 앱 실행은 되므로 실행 버튼은 막지 않고 안내만 한다.
    public static let terminalPluginVersion = [0, 3, 0]

    /// 실행 전 단계 실패(경로 없음·실행 불가)를 오류로 바꾼다.
    public static func pathFailure(_ code: IssueCode, path: String) -> EnvCheck {
        let message: String
        switch code {
        case .pathMissing: message = "Python 경로가 없습니다: \(path)"
        case .notExecutable: message = "실행할 수 없는 파일입니다: \(path)"
        default: message = "검사하지 못했습니다: \(path)"
        }
        return EnvCheck(status: .error, report: nil,
                        issues: [Issue(code: code, severity: .error, message: message, fixCommand: nil)])
    }

    /// 프로세스 실행 결과(종료 코드, 출력)를 해석한다.
    public static func interpret(exitCode: Int32, stdout: Data, stderr: String, timedOut: Bool,
                                 pythonPath: String, repoPath: String?) -> EnvCheck {
        if timedOut {
            return failure(.timedOut, "검사가 10초 안에 끝나지 않았습니다.")
        }
        if exitCode != 0 {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            return failure(.runFailed, "Python 실행에 실패했습니다(종료 코드 \(exitCode)). \(tail)")
        }
        guard let report = try? JSONDecoder().decode(CheckReport.self, from: stdout) else {
            return failure(.invalidOutput, "검사 결과를 해석하지 못했습니다.")
        }
        return interpret(report: report, pythonPath: pythonPath, repoPath: repoPath)
    }

    public static func interpret(report: CheckReport, pythonPath: String, repoPath: String?) -> EnvCheck {
        var issues: [Issue] = []
        let q = shellQuote(pythonPath)

        if !isAtLeast(report.pythonVersion, Interpreter.minPython) {
            issues.append(Issue(
                code: .pythonTooOld, severity: .error,
                message: "Python \(report.pythonVersionText)은 지원하지 않습니다. 3.9 이상이 필요합니다.",
                fixCommand: "uv venv ~/.venvs/<이름> --python 3.12"))
        }
        if report.pytestVersion == nil {
            issues.append(Issue(
                code: .pytestMissing, severity: .error,
                message: "pytest가 설치되어 있지 않습니다.",
                fixCommand: "uv pip install --python \(q) \"pytest>=8.4\""))
        }
        if !report.pluginInstalled {
            let repo = repoPath.map(shellQuote) ?? "<이 저장소 경로>"
            issues.append(Issue(
                code: .pluginMissing, severity: .actionNeeded,
                message: "pytest-menu-helper 플러그인이 설치되어 있지 않습니다.",
                fixCommand: "uv pip install --python \(q) -e \(repo)"))
        }
        if report.pluginInstalled, !pluginSupportsRunID(report.pluginVersion) {
            let repo = repoPath.map(shellQuote) ?? "<이 저장소 경로>"
            let have = report.pluginVersion.map { "(설치됨 \($0))" } ?? "(버전 확인 불가)"
            issues.append(Issue(
                code: .pluginOutdated, severity: .actionNeeded,
                message: "플러그인 업데이트가 필요합니다 \(have). 앱이 정한 실행 ID(PMH_RUN_ID)는 \(minPluginVersion.map(String.init).joined(separator: ".")) 이상에서 지원합니다.",
                fixCommand: "uv pip install --python \(q) -e \(repo)"))
        }
        // 0.2.x: 앱 실행은 정상이지만 다른 터미널 실행은 pid가 없어 끝났는지 확인할 수 없다(미완료로만 남는다).
        // 구버전(0.2.0 미만) 안내가 이미 있으면 같은 명령이 두 번 보이지 않게 넣지 않는다.
        if report.pluginInstalled, pluginSupportsRunID(report.pluginVersion),
           !isAtLeast(versionNumbers(report.pluginVersion), terminalPluginVersion) {
            let repo = repoPath.map(shellQuote) ?? "<이 저장소 경로>"
            issues.append(Issue(
                code: .pluginNoTerminalSupport, severity: .actionNeeded,
                message: "다른 터미널에서 실행한 pytest를 정확히 감지하려면 플러그인 \(terminalPluginVersion.map(String.init).joined(separator: ".")) 이상이 필요합니다(설치됨 \(report.pluginVersion ?? "?")). 앱에서 실행하는 데는 문제없습니다.",
                fixCommand: "uv pip install --python \(q) -e \(repo)"))
        }
        if report.fastapiVersion == nil {
            issues.append(Issue(
                code: .fastapiMissing, severity: .actionNeeded,
                message: "FastAPI가 설치되어 있지 않습니다(경고).",
                fixCommand: "uv pip install --python \(q) fastapi"))
        }
        let status = issues.map(\.severity).max() ?? .ready
        return EnvCheck(status: status, report: report, issues: issues)
    }

    private static func failure(_ code: IssueCode, _ message: String) -> EnvCheck {
        EnvCheck(status: .error, report: nil,
                 issues: [Issue(code: code, severity: .error, message: message, fixCommand: nil)])
    }

    /// "0.2.0", "0.2.0.dev1" 같은 버전의 숫자 부분만 비교한다. 읽을 수 없으면 미지원으로 본다.
    public static func pluginSupportsRunID(_ version: String?) -> Bool {
        let numbers = versionNumbers(version)
        return !numbers.isEmpty && isAtLeast(numbers, minPluginVersion)
    }

    /// 버전 문자열 앞쪽의 숫자 부분만 뽑는다("0.3.0.dev1" → [0, 3, 0]). 읽을 수 없으면 빈 목록.
    static func versionNumbers(_ version: String?) -> [Int] {
        guard let version = version else { return [] }
        var numbers: [Int] = []
        for part in version.split(separator: ".") {
            guard let n = Int(part.prefix(while: \.isNumber)), part.first?.isNumber == true else { break }
            numbers.append(n)
        }
        return numbers
    }

    static func isAtLeast(_ v: [Int], _ min: [Int]) -> Bool {
        for (a, b) in zip(v + [0, 0], min) where a != b { return a > b }
        return true
    }

    /// 셸에 붙여 넣어도 안전하도록 따옴표로 감싼다(공백·특수문자 포함 경로 대응).
    public static func shellQuote(_ s: String) -> String {
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+=:@".contains($0) }
        if safe && !s.isEmpty { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
