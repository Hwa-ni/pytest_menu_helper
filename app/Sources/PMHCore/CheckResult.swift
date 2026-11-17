import Foundation

public enum EnvStatus: Int, Comparable, Codable {
    case ready = 0        // 준비됨
    case actionNeeded = 1 // 조치 필요
    case error = 2        // 오류(사용 불가)

    public static func < (a: EnvStatus, b: EnvStatus) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .ready: return "준비됨"
        case .actionNeeded: return "조치 필요"
        case .error: return "오류"
        }
    }
}

public enum IssueCode: String, Codable {
    case pathMissing, notExecutable, runFailed, timedOut, invalidOutput
    case pythonTooOld, pytestMissing, pluginMissing, pluginOutdated, fastapiMissing
    /// 플러그인이 0.2.x라 앱 실행은 되지만 다른 터미널의 실행을 정확히 알아보지 못함(6단계, 실행 버튼은 막지 않음).
    case pluginNoTerminalSupport
}

public struct Issue: Equatable {
    public var code: IssueCode
    public var severity: EnvStatus
    public var message: String
    /// 사용자가 직접 실행할 설치 명령. 앱은 실행하지 않고 복사만 제공한다.
    public var fixCommand: String?
}

/// 검사 스크립트가 출력하는 JSON.
public struct CheckReport: Codable, Equatable {
    public var pythonVersion: [Int]
    public var pytestVersion: String?
    public var fastapiVersion: String?
    public var pluginInstalled: Bool
    /// 설치된 플러그인 버전. 설치 정보가 없으면 nil(구버전 판정).
    public var pluginVersion: String?
    /// sys.prefix의 실제 경로(가상환경 폴더). 다른 터미널 실행을 이 환경에 연결할 때 쓴다.
    /// 6단계 전에 만든 검사 결과에는 없을 수 있어 선택 값이다.
    public var prefix: String?

    enum CodingKeys: String, CodingKey {
        case pythonVersion = "python_version"
        case pytestVersion = "pytest_version"
        case fastapiVersion = "fastapi_version"
        case pluginInstalled = "plugin_installed"
        case pluginVersion = "plugin_version"
        case prefix
    }

    public init(pythonVersion: [Int], pytestVersion: String?, fastapiVersion: String?,
                pluginInstalled: Bool, pluginVersion: String? = nil, prefix: String? = nil) {
        self.pythonVersion = pythonVersion; self.pytestVersion = pytestVersion
        self.fastapiVersion = fastapiVersion; self.pluginInstalled = pluginInstalled
        self.pluginVersion = pluginVersion; self.prefix = prefix
    }

    public var pythonVersionText: String { pythonVersion.map(String.init).joined(separator: ".") }
}

/// 한 환경의 검사 결과(해석 완료).
public struct EnvCheck: Equatable {
    public var status: EnvStatus
    public var report: CheckReport?
    public var issues: [Issue]

    public var pythonVersionText: String? { report?.pythonVersionText }
}

public enum ProjectSummary: Equatable {
    case checking
    case noEnvironment
    case status(EnvStatus)

    public var label: String {
        switch self {
        case .checking: return "검사 중"
        case .noEnvironment: return "조치 필요"
        case .status(let s): return s.label
        }
    }

    /// nil은 아직 검사 중인 환경. 환경이 없으면 조치 필요(환경 추가), 가장 나쁜 상태가 프로젝트 상태.
    public static func summarize(_ checks: [EnvCheck?]) -> ProjectSummary {
        if checks.isEmpty { return .noEnvironment }
        if checks.contains(where: { $0 == nil }) { return .checking }
        return .status(checks.compactMap { $0?.status }.max() ?? .ready)
    }
}
