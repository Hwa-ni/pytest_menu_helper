// RunModels.swift
// pytest 실행의 상태·결과를 표현하는 값 타입과, 실행 버튼을 켤 수 있는지 판단하는 코드.
// 결과 문구(예: "실패 · 통과 1 · 실패 1")도 여기서 만든다. 화면(AppKit)은 이 문구를 그대로 보여 주기만 한다.

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

/// 집계기(`python -m pytest_menu_helper.aggregate`)가 돌려준 판정. Swift는 값을 옮겨 담기만 한다.
public struct RunSummary: Equatable, Decodable {
    public var state: String
    public var verdict: String?
    public var exitCode: Int?
    public var counts: [String: Int]
    public var runID: String?

    enum CodingKeys: String, CodingKey {
        case state, verdict, counts
        case exitCode = "exit_code"
        case runID = "run_id"
    }

    public init(state: String, verdict: String?, exitCode: Int?, counts: [String: Int], runID: String? = nil) {
        self.state = state; self.verdict = verdict; self.exitCode = exitCode; self.counts = counts; self.runID = runID
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

/// 한 번의 실행이 끝난 뒤의 결과. 결과 목록·상세는 5단계.
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

    public init(runID: String, envID: String, projectPath: String, phase: RunPhase, stopping: Bool) {
        self.runID = runID; self.envID = envID; self.projectPath = projectPath
        self.phase = phase; self.stopping = stopping
    }
}

public struct RunSnapshot: Equatable {
    public var active: ActiveRun?
    public var results: [String: RunOutcome] // 환경 id → 마지막 결과

    public init(active: ActiveRun? = nil, results: [String: RunOutcome] = [:]) {
        self.active = active; self.results = results
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
