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
    /// 앱이 띄우지 않은 프로세스(다른 터미널의 pytest)라 종료 코드를 알 수 없다. 프로세스가 사라진 것만 안다.
    case unknown

    public var text: String {
        switch self {
        case .unknown: return "프로세스 종료됨(종료 코드 모름)"
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
    /// 9단계: session_start의 pytest 실행 인수(명령줄에 준 것만, 설정 파일 addopts는 빠진다. docs/EVENTS.md).
    /// nil은 "알 수 없음"(키가 없는 옛 집계 결과, 형식이 틀린 값), []는 "인수 없이 실행함"이다. 둘을 섞으면
    /// 환경 비교(EnvComparison)가 서로 다른 실행 조건을 같다고 보거나, 같은 조건을 다르다고 경고한다.
    public var args: [String]?

    enum CodingKeys: String, CodingKey {
        case state, verdict, counts, tests, args
        case exitCode = "exit_code"
        case runID = "run_id"
        case projectRoot = "project_root"
        case notRun = "not_run"
        case collectionErrors = "collection_errors"
    }

    public init(state: String, verdict: String?, exitCode: Int?, counts: [String: Int], runID: String? = nil,
                projectRoot: String? = nil, tests: [TestResult] = [], notRun: [String] = [],
                collectionErrors: [CollectionErrorRecord] = [], args: [String]? = nil) {
        self.state = state; self.verdict = verdict; self.exitCode = exitCode; self.counts = counts; self.runID = runID
        self.projectRoot = projectRoot; self.tests = tests; self.notRun = notRun; self.collectionErrors = collectionErrors
        self.args = args
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
        // args는 판정에 쓰지 않는 참고 정보라, 모양이 틀려도(문자열 목록이 아님) 디코드 실패로 만들지 않고 nil로 둔다.
        // try?를 빼면 args 하나 때문에 결과 전체가 "집계 결과를 해석하지 못했습니다"가 된다(집계기 쪽 규칙과 같다).
        args = (try? c.decodeIfPresent([String].self, forKey: .args)) ?? nil
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
    /// 9단계: [모두 실행]에서 동시 실행 수(RunSnapshot.runLimit)가 다 차서 차례를 기다린다.
    /// 프로세스를 아직 띄우지 않았다. 앞 실행이 끝나면 RunController가 자동으로 시작한다.
    /// 터미널 실행(ExternalActive)에는 쓰지 않는다. 앱이 띄우지 않은 실행에는 대기 줄이 없다.
    case queued
    case waitingForEvents                    // 프로세스는 살아 있고 이벤트 파일이 아직 없다
    case running(done: Int, total: Int?)

    public var text: String {
        switch self {
        case .queued: return "차례 기다림"
        case .waitingForEvents: return "수집 대기"
        case .running(let done, let total): return "실행 중 \(done)/\(total.map(String.init) ?? "?")"
        }
    }
}

/// 앱이 맡은 실행 1건(실행 중이거나 차례를 기다리는 중). RunSnapshot.actives의 값이다.
public struct ActiveRun: Equatable {
    public var runID: String
    public var envID: String
    public var projectPath: String
    public var phase: RunPhase
    public var stopping: Bool
    /// 시작을 요청한 시각. 팝오버가 실행 중 경과 시간을 보여 줄 때 쓴다. 테스트에서 만든 값은 nil일 수 있다.
    /// 차례를 기다리던 실행은 대기 줄에 넣은 시각이었다가, 실제로 시작할 때 그 시각으로 바뀐다.
    public var startedAt: Date?
    /// 9단계: [모두 실행](RunController.startAll)으로 함께 시작한 실행의 묶음 ID. 낱개 ▶로 시작했으면 nil.
    public var batchID: String?

    public init(runID: String, envID: String, projectPath: String, phase: RunPhase, stopping: Bool,
                startedAt: Date? = nil, batchID: String? = nil) {
        self.runID = runID; self.envID = envID; self.projectPath = projectPath
        self.phase = phase; self.stopping = stopping; self.startedAt = startedAt; self.batchID = batchID
    }

    /// 차례를 기다리는 중인지(프로세스를 아직 띄우지 않았다).
    public var isQueued: Bool { phase == .queued }
}

/// 9단계: [모두 실행]으로 함께 시작한 묶음 1개의 상태. RunSnapshot.batches의 값이다.
/// 캐릭터·알림·환경 비교가 "같이 돌린 결과"를 묶는 기준이다(그 화면은 이 값을 읽기만 한다).
public struct BatchState: Equatable {
    /// 묶음에 든 환경 id(시작을 요청한 순서). 이미 실행 중이라 빠진 환경은 들어 있지 않다.
    public var envIDs: [String]
    /// 환경 id → 그 환경에 정한 실행 ID. 알림이 묶음의 실행 ID를 모두 "처리함"으로 넣을 때 쓴다.
    public var runIDs: [String: String]
    /// 묶음을 시작한 프로젝트 폴더.
    public var projectPath: String
    /// 묶음을 시작한 시각.
    public var startedAt: Date
    /// 결과가 정해진 환경 id(정상 종료·중지·실행 오류 모두 포함).
    public var completedEnvIDs: Set<String> = []
    /// 차례를 기다리다 사용자가 ■로 취소한 환경 id. 실행하지 않았으므로 결과가 없다.
    public var cancelledEnvIDs: Set<String> = []
    /// 모든 환경이 끝나거나 취소된 시각. 아직 남은 환경이 있으면 nil.
    public var finishedAt: Date?

    public init(envIDs: [String], runIDs: [String: String], projectPath: String, startedAt: Date,
                completedEnvIDs: Set<String> = [], cancelledEnvIDs: Set<String> = [], finishedAt: Date? = nil) {
        self.envIDs = envIDs; self.runIDs = runIDs; self.projectPath = projectPath; self.startedAt = startedAt
        self.completedEnvIDs = completedEnvIDs; self.cancelledEnvIDs = cancelledEnvIDs; self.finishedAt = finishedAt
    }

    /// 묶음의 모든 환경이 끝났거나(결과 있음) 취소됐는지.
    public var isFinished: Bool {
        envIDs.allSatisfy { completedEnvIDs.contains($0) || cancelledEnvIDs.contains($0) }
    }
}

/// 실행 상태 전체. 결과는 메모리에만 있고 앱을 다시 시작하면 사라진다(보존은 11단계).
/// RunController는 앱 실행 값(actives, results, elapsed, finishedAt, runIDs, batchIDs, batches, runLimit)만 채운다.
/// 외부 실행 값(external, sources, unregistered)은 merged(external:)가 감시기 상태를 합쳐 채운다.
public struct RunSnapshot: Equatable {
    /// 9단계: 환경 id → 앱이 맡은 실행(실행 중 또는 차례 기다림). 한 환경에는 동시에 1건만 있다.
    /// 같은 가상환경을 두 번 동시에 돌리면 결과 키가 겹치고 비교 의미도 없어서다.
    public var actives: [String: ActiveRun]
    public var results: [String: RunOutcome] // 환경 id → 마지막 결과
    /// 환경 id → 마지막 실행의 소요 시간(초). pytest 프로세스 시작부터 종료까지이며 집계 호출 시간은 뺀다.
    /// 시작하지 못한 실행(launchFailed)은 값이 없다.
    public var elapsed: [String: TimeInterval]
    /// 환경 id → 마지막 결과가 정해진 시각. 앱 실행과 외부 실행 중 최신 결과를 고를 때 쓴다.
    public var finishedAt: [String: Date] = [:]
    /// 환경 id → 마지막 결과의 출처. 키가 없으면 앱 실행이다.
    public var sources: [String: RunSource] = [:]
    /// 환경 id → 마지막 결과를 낸 실행 ID(8단계). 완료 알림을 실행마다 한 번만 보내는 데 쓴다
    /// (NotificationPresentation.decisions). 결과(results)와 함께 바뀐다. 키가 없으면 실행 ID를 모르는 결과다.
    public var runIDs: [String: String] = [:]
    /// 9단계: 환경 id → 마지막 결과를 낸 실행의 묶음 ID. 낱개 ▶나 터미널 실행 결과면 키가 없다.
    /// 결과(results)와 함께 바뀐다. 같은 환경을 낱개로 다시 돌리면 키가 지워진다.
    public var batchIDs: [String: String] = [:]
    /// 9단계: 묶음 ID → 묶음 상태. 끝나지 않았거나, 끝났어도 어느 환경의 결과(batchIDs)가 아직 그 묶음을
    /// 가리키는 묶음만 남는다. 모든 환경이 다른 실행으로 바뀐 묶음은 RunController가 지운다.
    public var batches: [String: BatchState] = [:]
    /// 9단계: 앱이 동시에 띄울 수 있는 실행 수(RunController.maxConcurrentRuns, 테스트에서는 바꿀 수 있다).
    /// 화면이 ▶를 끌지와 도움말 숫자를 이 값으로 정한다.
    public var runLimit: Int = RunController.maxConcurrentRuns
    /// 환경 id → 진행 중인 외부 실행(같은 환경에 여럿이면 가장 나중에 시작한 것).
    public var external: [String: ExternalActive] = [:]
    /// 등록하지 않은 환경에서 실행한 최근 외부 실행(감시기 값 그대로).
    public var unregistered: [UnregisteredRun] = []

    public init(actives: [String: ActiveRun] = [:], results: [String: RunOutcome] = [:],
                elapsed: [String: TimeInterval] = [:]) {
        self.actives = actives; self.results = results; self.elapsed = elapsed
    }

    /// 프로세스를 띄운(차례 기다림이 아닌) 실행 수. 동시 실행 제한은 이 수로 센다.
    public var runningCount: Int { actives.values.filter { !$0.isQueued }.count }

    /// 동시 실행 수가 다 차서 낱개 ▶를 더 받을 수 없는지.
    public var isAtRunLimit: Bool { runningCount >= runLimit }

    /// 앱이 맡은 실행이 있는 환경 id 전체(차례 기다림 포함). 환경·프로젝트 제거 막기에 쓴다.
    /// 차례 기다림도 넣는 이유: 대기 중인 환경을 지우면 그 행(■ 대기 취소)이 사라져 대기를 취소할 수 없고,
    /// 나중에 등록에 없는 환경이 저절로 실행된다.
    public var runningEnvIDs: Set<String> { Set(actives.keys) }

    /// 프로세스를 띄운 실행 중 가장 나중에 시작한 것. 팝오버 기본 선택처럼 "지금 돌고 있는 하나"가 필요할 때 쓴다.
    /// 시작 시각이 없는 값(테스트에서 만든 값)은 가장 늦은 것으로 본다. 같으면 환경 id 순서로 정해 결과가 흔들리지 않게 한다.
    public var latestActive: ActiveRun? {
        actives.values.filter { !$0.isQueued }.max {
            let l = $0.startedAt ?? .distantFuture, r = $1.startedAt ?? .distantFuture
            return l != r ? l < r : $0.envID > $1.envID
        }
    }

    /// 앱 실행 상태(self)에 외부 실행 상태를 합친다. 순수 함수다.
    /// - Parameter external: 감시기 상태.
    /// - Returns: 환경마다 앱 실행과 외부 실행 중 나중에 끝난 결과를 "마지막 결과"로 둔 상태.
    /// 규칙: 앱 결과가 없거나, 앱 결과 시각을 모르거나(이전 형식 값), 외부 결과가 더 늦게 끝났으면 외부 결과를 쓴다.
    /// 같은 실행이 두 번 보이지 않는 이유: 감시기는 앱이 시작한 실행 ID를 처음부터 제외하므로
    /// 한 실행은 앱 쪽 또는 외부 쪽 한 곳에만 있다.
    /// 9단계 필드: actives·batches·runLimit은 앱 실행 값이라 그대로 둔다. batchIDs는 아래 규칙을 따른다.
    public func merged(external ext: ExternalSnapshot) -> RunSnapshot {
        var s = self
        for (envID, r) in ext.results {
            if let appTime = finishedAt[envID], results[envID] != nil, appTime >= r.finishedAt { continue }
            s.results[envID] = r.outcome
            s.elapsed[envID] = r.elapsed
            s.finishedAt[envID] = r.finishedAt
            s.sources[envID] = .terminal
            // 결과와 실행 ID를 같이 바꾼다. 빠뜨리면 터미널 결과에 앱 실행 ID가 붙어 알림이 중복되거나 빠진다.
            s.runIDs[envID] = r.runID
            // 터미널 결과는 어느 묶음에도 속하지 않으므로 묶음 ID를 지운다. 남기면 캐릭터·알림·비교가
            // 터미널에서 따로 돌린 결과를 "함께 실행한 묶음"의 결과로 세어, 같은 시점 비교라고 잘못 보여 준다.
            // batches는 지우지 않는다. 묶음이 끝났는지는 앱 실행 기준이고, 결과가 바뀐 환경은 batchIDs로 가린다.
            s.batchIDs[envID] = nil
        }
        // active는 시작 시각 순이라 뒤의 것이 덮어써 "가장 나중에 시작한 실행"이 남는다.
        for a in ext.active { s.external[a.envID] = a }
        s.unregistered = ext.unregistered
        return s
    }
}

/// 낱개 시작(RunController.start)의 결과.
public enum StartResult: Equatable {
    case started(runID: String)
    /// 이 환경이 이미 실행 중이거나 차례를 기다리는 중이다(한 환경에는 동시에 1건만).
    case alreadyRunning
    /// 9단계: 동시 실행 수(RunSnapshot.runLimit)가 다 찼다. 낱개 ▶는 대기 줄에 넣지 않고 거절한다.
    case limitReached
}

/// 9단계: [모두 실행]에 넘기는 환경 1개.
public struct RunTarget: Equatable {
    /// 등록한 환경 id. 결과와 실행 상태의 키이며 자식 프로세스의 PMH_ENV_ID다.
    public var envID: String
    /// 이 환경의 python 경로. 앱은 이 python의 `-m pytest`만 실행한다.
    public var pythonPath: String

    public init(envID: String, pythonPath: String) { self.envID = envID; self.pythonPath = pythonPath }
}

/// 9단계: [모두 실행](RunController.startAll)의 결과.
public struct BatchStartResult: Equatable {
    /// 만든 묶음 ID. 시작하거나 대기 줄에 넣은 환경이 하나도 없으면 nil(묶음을 만들지 않았다).
    public var batchID: String?
    /// 바로 시작한 환경 id(요청 순서).
    public var started: [String]
    /// 동시 실행 수가 다 차서 대기 줄에 넣은 환경 id(요청 순서). 앞 실행이 끝나면 자동으로 시작한다.
    public var queued: [String]
    /// 이미 실행 중이거나 대기 중이라 묶음에 넣지 않은 환경 id.
    public var alreadyRunning: [String]
    /// 환경 id → 정한 실행 ID(시작·대기 모두).
    public var runIDs: [String: String]

    public init(batchID: String?, started: [String], queued: [String], alreadyRunning: [String],
                runIDs: [String: String]) {
        self.batchID = batchID; self.started = started; self.queued = queued
        self.alreadyRunning = alreadyRunning; self.runIDs = runIDs
    }
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
