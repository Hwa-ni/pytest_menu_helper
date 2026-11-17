import Foundation

/// 검사 결과 해석(순수 함수). 프로세스·파일에 접근하지 않는다.
public enum Interpreter {
    public static let minPython = [3, 9]

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
