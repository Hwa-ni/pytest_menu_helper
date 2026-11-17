// RunModels.swift
// pytest 실행의 상태·결과를 표현하는 값 타입과, 실행 버튼을 켤 수 있는지 판단하는 코드.
// 결과 문구(예: "실패 · 통과 1 · 실패 1")도 여기서 만든다. 화면(AppKit)은 이 문구를 그대로 보여 주기만 한다.
// 5단계부터 집계기 JSON의 테스트 목록(tests), 미실행 목록(not_run), 수집 오류(collection_errors)도 디코드한다.
// 화면이 쓰는 값(건수, 실패 목록, 링 값)은 ResultPresentation.swift가 이 값들로 만든다.

import Foundation

/// 프로세스가 끝난 방식.
public enum Termination: Equatable {
    case exit(Int32)
    case signal(Int32)

    public var text: String {
        switch self {
        case .exit(let code): return "종료 코드 \(code)"
        case .signal(let n):
            let names: [Int32: String] = [1: "HUP", 2: "INT", 6: "ABRT", 9: "KILL", 11: "SEGV", 15: "TERM"]
            return "시그널 \(n)" + (names[n].map { "(\($0))" } ?? "")
        }
    }
}

/// 소스 위치(테스트 정의 위치나 실패 위치). 집계기 JSON의 `{path, line}`.
/// pytest가 위치를 주지 못하면 두 값 모두 null일 수 있어 선택 값으로 둔다.
public struct SourceLocation: Equatable, Decodable {
    public var path: String?
    public var line: Int?

    public init(path: String?, line: Int?) { self.path = path; self.line = line }
}

/// 실패 정보. 집계기 JSON의 `failure: {path, line, message, detail}`.
/// message는 한 줄 요약(예: "AssertionError: ..."), detail은 pytest가 만든 traceback 전체다.
/// 어느 필드든 null일 수 있다(pytest가 제공하지 못한 경우).
public struct FailureInfo: Equatable, Decodable {
    public var path: String?
    public var line: Int?
    public var message: String?
    public var detail: String?

    public init(path: String? = nil, line: Int? = nil, message: String? = nil, detail: String? = nil) {
        self.path = path; self.line = line; self.message = message; self.detail = detail
    }
}

/// 테스트 한 단계(setup/call/teardown)의 이벤트에서 화면이 쓰는 필드만 담는다.
/// 이벤트에는 seq·timestamp 등 다른 필드도 있지만 디코드하지 않는다(모르는 키는 무시된다).
public struct PhaseReport: Equatable, Decodable {
    /// pytest report의 outcome: passed / failed / skipped.
    public var outcome: String?
    /// 단계 소요 시간(초).
    public var duration: Double?
    /// 테스트 정의 위치.
    public var location: SourceLocation?
    /// 실패한 단계만 값이 있다.
    public var failure: FailureInfo?

    public init(outcome: String?, duration: Double? = nil, location: SourceLocation? = nil, failure: FailureInfo? = nil) {
        self.outcome = outcome; self.duration = duration; self.location = location; self.failure = failure
    }
}

/// 집계기가 테스트 ID(+반복 번호)별로 합친 결과 한 건. 집계기 JSON의 `tests[]`.
/// status는 집계기가 정한 값(passed, failed, error, skipped, xfailed, xpassed, incomplete)을 그대로 쓴다.
/// Swift는 판정을 다시 하지 않는다.
public struct TestResult: Equatable, Decodable {
    public var nodeid: String
    /// 같은 nodeid가 한 실행에서 반복 수집된 순서(1부터). 이전 이벤트에서는 없을 수 있어 1로 본다.
    public var occurrence: Int
    public var status: String
    /// 단계 이름("setup"/"call"/"teardown") → 그 단계 이벤트. 보고되지 않은 단계는 키가 없다.
    public var phases: [String: PhaseReport]

    /// 단계 이름을 실행 순서대로 둔 목록. 실패 정보를 이 순서로 보여 주기 위해 쓴다.
    public static let phaseOrder = ["setup", "call", "teardown"]

    enum CodingKeys: String, CodingKey { case nodeid, occurrence, status, phases }

    public init(nodeid: String, occurrence: Int = 1, status: String, phases: [String: PhaseReport] = [:]) {
        self.nodeid = nodeid; self.occurrence = occurrence; self.status = status; self.phases = phases
    }

    /// occurrence와 phases는 없어도 받아들인다. 필수는 nodeid와 status뿐이다.
    /// 빠뜨리면 이전 형식 기록 하나 때문에 결과 전체가 "집계 결과를 해석하지 못했습니다"로 바뀐다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeid = try c.decode(String.self, forKey: .nodeid)
        status = try c.decode(String.self, forKey: .status)
        occurrence = try c.decodeIfPresent(Int.self, forKey: .occurrence) ?? 1
        phases = try c.decodeIfPresent([String: PhaseReport].self, forKey: .phases) ?? [:]
    }

    /// 테스트 정의 위치. 어느 단계에서든 먼저 보이는 값을 쓴다(단계마다 같은 값이 들어 있다).
    public var location: SourceLocation? {
        Self.phaseOrder.lazy.compactMap { self.phases[$0]?.location }.first
    }

    /// 보고된 단계 소요 시간의 합(초). 보고된 단계가 없으면 nil.
    public var duration: Double? {
        let values = Self.phaseOrder.compactMap { phases[$0]?.duration }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// 실패 정보가 있는 단계와 그 실패를 실행 순서대로 돌려준다.
    /// 오류(error)는 setup·teardown 실패라 call이 아닌 단계에 실패가 들어 있을 수 있다.
    public var failures: [(phase: String, failure: FailureInfo)] {
        Self.phaseOrder.compactMap { name in phases[name]?.failure.map { (name, $0) } }
    }

    /// 보고되지 않은 단계 이름(실행 순서대로). 미완료 테스트에서 무엇이 빠졌는지 보여 줄 때 쓴다.
    /// call은 setup이 skip·실패하면 원래 없으므로, setup·teardown 누락만 센다.
    public var missingPhases: [String] {
        ["setup", "teardown"].filter { phases[$0] == nil }
    }
}

/// 수집 오류 한 건. 집계기 JSON의 `collection_errors[]`(collection_error 이벤트 원본).
/// 테스트 모듈 import 실패 등이라 테스트 목록(tests)에는 없다.
public struct CollectionErrorRecord: Equatable, Decodable {
    public var nodeid: String?
    public var failure: FailureInfo?

    public init(nodeid: String?, failure: FailureInfo?) { self.nodeid = nodeid; self.failure = failure }
}

/// 집계기(`python -m pytest_menu_helper.aggregate`)가 돌려준 판정. Swift는 값을 옮겨 담기만 한다.
public struct RunSummary: Equatable, Decodable {
    public var state: String
    public var verdict: String?
    public var exitCode: Int?
    public var counts: [String: Int]
    public var runID: String?
    /// pytest가 정한 rootdir. 실패 위치를 이 폴더 기준 상대 경로로 보여 줄 때 쓴다.
    public var projectRoot: String?
    /// 테스트별 결과(집계기의 수집 순서가 아니라 보고된 순서).
    public var tests: [TestResult]
    /// 수집됐지만 어느 단계도 보고되지 않은 테스트 ID(수집 순서).
    public var notRun: [String]
    /// 수집 오류 목록.
    public var collectionErrors: [CollectionErrorRecord]

    enum CodingKeys: String, CodingKey {
        case state, verdict, counts, tests
        case exitCode = "exit_code"
        case runID = "run_id"
        case projectRoot = "project_root"
        case notRun = "not_run"
        case collectionErrors = "collection_errors"
    }

    public init(state: String, verdict: String?, exitCode: Int?, counts: [String: Int], runID: String? = nil,
                projectRoot: String? = nil, tests: [TestResult] = [], notRun: [String] = [],
                collectionErrors: [CollectionErrorRecord] = []) {
        self.state = state; self.verdict = verdict; self.exitCode = exitCode; self.counts = counts; self.runID = runID
        self.projectRoot = projectRoot; self.tests = tests; self.notRun = notRun; self.collectionErrors = collectionErrors
    }

    /// 4단계 형식(목록 필드 없음)도 읽는다. 목록 필드가 없으면 빈 목록으로 둔다.
    /// state·counts는 필수다. 없으면 판정을 할 수 없으므로 디코드 실패(집계 오류)로 둔다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        counts = try c.decode([String: Int].self, forKey: .counts)
        runID = try c.decodeIfPresent(String.self, forKey: .runID)
        projectRoot = try c.decodeIfPresent(String.self, forKey: .projectRoot)
        tests = try c.decodeIfPresent([TestResult].self, forKey: .tests) ?? []
        notRun = try c.decodeIfPresent([String].self, forKey: .notRun) ?? []
        collectionErrors = try c.decodeIfPresent([CollectionErrorRecord].self, forKey: .collectionErrors) ?? []
    }

    public var title: String {
        if let verdict = verdict {
            switch verdict {
            case "passed": return "성공"
            case "failed": return "실패"
            default: return "확인 필요"
            }
        }
        switch state {
        case "no_tests": return "테스트 없음"
        case "collection_error": return "수집 오류"
        case "interrupted": return "중단됨"
        case "incomplete": return "미완료"
        case "waiting": return "대기"
        case "running": return "실행 중"
        default: return state
        }
    }

    /// 통과·실패는 항상, 나머지는 0이 아닐 때만 보여 준다.
    public var countsText: String {
        func n(_ key: String) -> Int { counts[key] ?? 0 }
        var parts = ["통과 \(n("passed"))", "실패 \(n("failed"))"]
        for (key, label) in [("error", "오류"), ("skipped", "skip"), ("xfailed", "xfail"),
                             ("xpassed", "xpass"), ("incomplete", "미완료"),
                             // not_run: 수집됐지만 시작도 못 한 테스트(중지·-x 등). 집계기가 센 값을 그대로 쓴다.
                             ("not_run", "미실행")] where n(key) > 0 {
            parts.append("\(label) \(n(key))")
        }
        return parts.joined(separator: " · ")
    }
}

/// 한 번의 실행이 끝난 뒤의 결과. 목록·상세 화면 값은 ResultPresentation이 만든다.
public enum RunOutcome: Equatable {
    /// 종료 이벤트가 있고 집계기로 판정했다.
    case finished(RunSummary)
    /// 프로세스는 끝났는데 session_finish가 없다(강제 종료 등).
    case incomplete(termination: Termination, stopped: Bool, done: Int, total: Int?)
    /// 프로세스가 끝났는데 이벤트가 하나도 없다.
    case collectionFailed(termination: Termination, logTail: String?)
    /// 집계 호출 실패(구버전 플러그인 등). 판정이 아니라 오류다.
    case aggregationFailed(message: String)
    /// 앱이 정한 run_id와 다른 이벤트가 섞였다.
    case eventsMixed(foreign: Int)
    case launchFailed(message: String)

    public var title: String {
        switch self {
        case .finished(let s): return "\(s.title) · \(s.countsText)"
        case .incomplete(let t, let stopped, let done, let total):
            let progress = total.map { " · \(done)/\($0) 끝남" } ?? (done > 0 ? " · \(done)건 끝남" : "")
            return "미완료 · \(t.text)" + (stopped ? " · 중지함" : "") + progress
        case .collectionFailed(let t, _): return "수집 실패 · \(t.text)"
        case .aggregationFailed: return "집계 오류"
        case .eventsMixed(let n): return "집계 오류 · 다른 실행 이벤트 \(n)건 섞임"
        case .launchFailed: return "실행 오류"
        }
    }

    public var detail: String? {
        switch self {
        case .collectionFailed(_, let tail):
            return tail.map { "로그 마지막 줄: \($0)" } ?? "이벤트가 없습니다. 로그 파일을 확인하세요."
        case .aggregationFailed(let m), .launchFailed(let m): return m
        default: return nil
        }
    }
}

public enum RunPhase: Equatable {
    case waitingForEvents                    // 프로세스는 살아 있고 이벤트 파일이 아직 없다
    case running(done: Int, total: Int?)

    public var text: String {
        switch self {
        case .waitingForEvents: return "수집 대기"
        case .running(let done, let total): return "실행 중 \(done)/\(total.map(String.init) ?? "?")"
        }
    }
}

public struct ActiveRun: Equatable {
    public var runID: String
    public var envID: String
    public var projectPath: String
    public var phase: RunPhase
    public var stopping: Bool
    /// 시작을 요청한 시각. 팝오버가 실행 중 경과 시간을 보여 줄 때 쓴다. 테스트에서 만든 값은 nil일 수 있다.
    public var startedAt: Date?

    public init(runID: String, envID: String, projectPath: String, phase: RunPhase, stopping: Bool,
                startedAt: Date? = nil) {
        self.runID = runID; self.envID = envID; self.projectPath = projectPath
        self.phase = phase; self.stopping = stopping; self.startedAt = startedAt
    }
}

/// 실행 상태 전체. 결과는 메모리에만 있고 앱을 다시 시작하면 사라진다(보존은 11단계).
public struct RunSnapshot: Equatable {
    public var active: ActiveRun?
    public var results: [String: RunOutcome] // 환경 id → 마지막 결과
    /// 환경 id → 마지막 실행의 소요 시간(초). pytest 프로세스 시작부터 종료까지이며 집계 호출 시간은 뺀다.
    /// 시작하지 못한 실행(launchFailed)은 값이 없다.
    public var elapsed: [String: TimeInterval]

    public init(active: ActiveRun? = nil, results: [String: RunOutcome] = [:], elapsed: [String: TimeInterval] = [:]) {
        self.active = active; self.results = results; self.elapsed = elapsed
    }
}

public enum StartResult: Equatable {
    case started(runID: String)
    case alreadyRunning
}

/// 실행 버튼을 켤 수 있는지. 환경 검사 결과로만 판단한다.
public enum RunEligibility {
    public static func reason(for check: EnvCheck?) -> String? {
        guard let check = check else { return "환경 검사 중입니다." }
        if let e = check.issues.first(where: { $0.severity == .error }) { return e.message }
        if let p = check.issues.first(where: { $0.code == .pluginMissing || $0.code == .pluginOutdated }) {
            return p.message
        }
        return nil
    }
}
