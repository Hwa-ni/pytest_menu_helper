// ResultPresentation.swift
// 팝오버 화면(5단계 결과 목록과 실패 상세)이 보여 줄 값을 만드는 순수 코드. AppKit·SwiftUI를 쓰지 않는다.
// 입력: 등록 정보(Registry), 환경 검사 결과(EnvCheck), 실행 상태(RunSnapshot), 사용자가 고른 프로젝트·환경 id.
// 출력: PopoverState. 화면은 이 값을 그대로 그리기만 하고 판정이나 건수 계산을 하지 않는다.
// 판정(성공·실패 등)은 여전히 Python 집계기가 정한 값(RunSummary)을 옮겨 쓴다. 여기서는 표시 문구와
// 링·건수·실패 목록처럼 "보여 주는 방법"만 정한다.
// 9단계(다중 환경 동시 실행)를 위해 환경을 항상 목록(rows)으로 다룬다. 지금은 동시에 1건만 실행되지만
// 행마다 상태·진행을 따로 계산하므로, 실행이 여러 건이 되어도 이 구조를 그대로 쓸 수 있다.

import Foundation

/// 상태 점과 문구 색을 정하는 분류. 실제 색은 화면 쪽이 시스템 색으로 고른다(다크·라이트 대응).
public enum StatusTone: Equatable {
    /// 아직 실행하지 않음, 또는 건수 0 같은 중립 상태.
    case idle
    /// 환경 검사 중.
    case checking
    /// 실행 중(수집 대기 포함).
    case running
    /// 전체 통과.
    case passed
    /// 실패·오류·수집 오류·집계 오류 등 사용자가 원인을 봐야 하는 상태.
    case failed
    /// skip·xfail·중단·미완료처럼 성공도 실패도 아닌 상태.
    case attention
    /// 환경 문제로 실행할 수 없음.
    case unavailable
}

/// 세부 사항의 건수 한 줄(색 점 + 이름 + 수).
public struct CountItem: Equatable, Identifiable {
    /// 집계기 counts의 키(passed, failed, ...). 화면의 반복 식별자로도 쓴다.
    public var key: String
    public var label: String
    public var value: Int
    public var tone: StatusTone
    public var id: String { key }
    /// 0인 항목은 화면에서 흐리게 보여 준다.
    public var isZero: Bool { value == 0 }
}

/// 링 하나의 값. fraction이 nil이면 채우지 않은 빈 링(값을 모름)으로 그린다.
public struct RingModel: Equatable {
    /// 0~1. 범위를 벗어난 값은 만들 때 잘라 둔다.
    public var fraction: Double?
    /// 링 가운데 큰 글자.
    public var center: String
    /// 링 아래 작은 설명.
    public var caption: String

    public init(fraction: Double?, center: String, caption: String) {
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.center = center
        self.caption = caption
    }
}

/// 실패 상세의 한 묶음(단계 하나의 실패 또는 안내 문장).
public struct FailureSection: Equatable {
    /// 예: "call 단계", "수집 단계", "기록되지 않은 단계".
    public var title: String
    /// 한 줄 요약(예: "AssertionError: assert 200 == 500").
    public var message: String?
    /// traceback 전체. 고정폭 글꼴로 스크롤해 보여 준다.
    public var detail: String?
}

/// 실패한 테스트 목록의 한 줄과, 눌렀을 때 펼쳐 보여 줄 내용.
public struct FailureEntry: Equatable, Identifiable {
    /// 목록 안에서 유일한 값. 테스트는 "nodeid#반복 번호", 수집 오류는 "collect#순번".
    public var id: String
    /// 보여 줄 테스트 이름(반복 실행이면 "(2번째)"를 덧붙인다).
    public var title: String
    /// "실패", "오류", "미완료", "수집 오류".
    public var statusLabel: String
    public var tone: StatusTone
    /// "파일:줄". 실제 실패 위치를 우선하고, 없으면 테스트 정의 위치. 둘 다 없으면 nil.
    public var locationText: String?
    /// 접힌 상태에서 보여 줄 한 줄 요약.
    public var summary: String?
    public var sections: [FailureSection]
}

/// 선택한 환경의 상세(링 3개, 세부 건수, 실패 목록).
public struct EnvDetailModel: Equatable {
    public var envID: String
    /// 상세 맨 위 제목(예: "실패", "실행 중 3/5").
    public var headline: String
    public var tone: StatusTone
    /// 왼쪽 링: 진행률(끝난 테스트 / 수집 수).
    public var progressRing: RingModel
    /// 가운데 링: 통과율(통과 / 수집 수).
    public var passRing: RingModel
    /// 오른쪽: 소요 시간 문구. 실행 중이면 liveStartedAt으로 화면이 직접 갱신한다.
    public var elapsedText: String
    /// 실행 중일 때 시작 시각. 화면이 1초마다 경과 시간을 다시 그릴 때 쓴다. 끝난 실행은 nil.
    public var liveStartedAt: Date?
    /// 세부 건수. 집계 결과가 없으면(실행 중, 미완료, 오류) 비어 있다.
    public var counts: [CountItem]
    public var failures: [FailureEntry]
    /// 상세 아래에 보여 줄 안내 문장들(미실행 설명, 오류 내용, 실행 불가 이유 등).
    public var notes: [String]
}

/// 환경 행 오른쪽 버튼.
public enum RowAction: Equatable {
    /// 실행(▶). enabled가 false면 꺼진 버튼으로 보여 준다.
    case run(enabled: Bool)
    /// 중지(■). 이미 중지하는 중이면 꺼진다.
    case stop(enabled: Bool)
}

/// 환경 목록의 한 줄.
public struct EnvRowModel: Equatable, Identifiable {
    /// 환경 id(PMHEnvironment.id).
    public var id: String
    public var name: String
    /// 예: "Python 3.13.18", 검사 전이면 "검사 중".
    public var versionText: String
    public var tone: StatusTone
    public var statusText: String
    /// 진행 바 값(0~1). nil이면 진행 바를 숨긴다. indeterminate가 true면 값 없이 움직이는 바를 그린다.
    public var progress: Double?
    public var indeterminate: Bool
    /// 진행 바 옆 "done/total". 진행 바가 없으면 nil.
    public var progressText: String?
    public var action: RowAction
    /// 버튼에 마우스를 올렸을 때 보여 줄 설명(꺼진 이유 등).
    public var actionHelp: String?
    public var isSelected: Bool
}

/// 프로젝트 고르기 목록의 항목.
public struct ProjectOption: Equatable, Identifiable {
    public var id: UUID
    public var name: String
}

/// 팝오버 전체 상태.
public struct PopoverState: Equatable {
    public var projects: [ProjectOption]
    public var selectedProjectID: UUID?
    public var rows: [EnvRowModel]
    public var selectedEnvID: String?
    public var detail: EnvDetailModel?
    /// 프로젝트나 환경이 없을 때 보여 줄 안내. 있으면 목록 대신 이 문장을 보여 준다.
    public var emptyMessage: String?

    /// 빈 상태(프로젝트 없음). 화면 쪽 뷰 모델의 첫 값으로 쓴다.
    public static let empty = PopoverState(projects: [], selectedProjectID: nil, rows: [], selectedEnvID: nil,
                                           detail: nil, emptyMessage: nil)
}

/// 팝오버 값을 만드는 함수 모음. 모두 입력만 보고 결과를 돌려주는 순수 함수다.
public enum ResultPresentation {
    /// 세부 사항에 보여 줄 건수 키와 이름·색. 순서도 화면 순서다.
    /// 미실행(not_run)은 결과가 아니라 "시작 못 함"이라 중립 색, 미완료는 판정이 없는 상태라 주의 색을 쓴다.
    static let countOrder: [(key: String, label: String, tone: StatusTone)] = [
        ("passed", "통과", .passed), ("failed", "실패", .failed), ("error", "오류", .failed),
        ("skipped", "skip", .attention), ("xfailed", "xfail", .attention), ("xpassed", "xpass", .attention),
        ("not_run", "미실행", .idle), ("incomplete", "미완료", .attention),
    ]

    // MARK: 건수

    /// 세부 사항 건수 목록을 만든다. 집계기가 주지 않은 키는 0으로 본다.
    /// - Parameter counts: 집계기 JSON의 counts.
    /// - Returns: countOrder 순서의 8개 항목(0인 항목도 빠뜨리지 않는다. 화면이 흐리게 보여 준다).
    public static func countItems(_ counts: [String: Int]) -> [CountItem] {
        countOrder.map { CountItem(key: $0.key, label: $0.label, value: counts[$0.key] ?? 0, tone: $0.tone) }
    }

    /// 수집 수. 집계기는 수집 수를 따로 주지 않으므로 상태별 건수를 모두 더한다.
    /// 테스트 결과(tests)와 미실행(not_run)은 겹치지 않으므로(집계기 규칙) 합이 곧 수집 수다.
    /// 같은 nodeid가 반복 수집되면 반복마다 1건으로 센다(pytest 터미널 요약과 같은 방식).
    public static func collectedTotal(_ counts: [String: Int]) -> Int {
        countOrder.reduce(0) { $0 + (counts[$1.key] ?? 0) }
    }

    /// 끝난 테스트 수. 미실행(시작 못 함)과 미완료(일부 단계만 보고됨)를 뺀다.
    public static func finishedCount(_ counts: [String: Int]) -> Int {
        collectedTotal(counts) - (counts["not_run"] ?? 0) - (counts["incomplete"] ?? 0)
    }

    // MARK: 링과 시간

    /// 진행률 링. total이 nil(수집 전)이거나 0이면 값을 채우지 않는다(0으로 나누지 않기 위함).
    public static func progressRing(done: Int, total: Int?) -> RingModel {
        guard let total = total else { return RingModel(fraction: nil, center: "\(done)/?", caption: "진행") }
        return RingModel(fraction: total > 0 ? Double(done) / Double(total) : nil,
                         center: "\(done)/\(total)", caption: "진행")
    }

    /// 통과율 링(통과 / 수집 수). 수집 수가 0이면 "—".
    /// 반올림 때문에 통과가 1건 모자란데 "100%"로 보이지 않도록, 전부 통과가 아니면 99%에서 멈춘다.
    public static func passRing(passed: Int, total: Int) -> RingModel {
        guard total > 0 else { return RingModel(fraction: nil, center: "—", caption: "통과 0/0") }
        let fraction = Double(passed) / Double(total)
        var percent = Int((fraction * 100).rounded())
        if passed < total { percent = min(percent, 99) }
        return RingModel(fraction: fraction, center: "\(percent)%", caption: "통과 \(passed)/\(total)")
    }

    /// 값을 모를 때 쓰는 빈 링.
    public static func emptyRing(caption: String) -> RingModel {
        RingModel(fraction: nil, center: "—", caption: caption)
    }

    /// 소요 시간 문구. 10초 미만은 소수 1자리, 1분 미만은 초, 1시간 미만은 분·초, 그 이상은 시간·분.
    /// - Parameter seconds: 초. 음수(시계 보정 등)는 0으로 본다.
    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = max(seconds, 0)
        if s < 10 { return String(format: "%.1f초", s) }
        let whole = Int(s)
        if whole < 60 { return "\(whole)초" }
        if whole < 3600 { return "\(whole / 60)분 \(whole % 60)초" }
        return "\(whole / 3600)시간 \((whole % 3600) / 60)분"
    }

    // MARK: 행 상태 문구

    /// 끝난 실행의 행 문구와 색.
    /// 실패 수는 실패(failed)와 오류(error)를 합친다. 둘 다 사용자가 고쳐야 하는 결과이기 때문이다.
    public static func outcomeStatus(_ outcome: RunOutcome) -> (text: String, tone: StatusTone) {
        switch outcome {
        case .finished(let s):
            switch s.verdict {
            case "passed": return ("통과", .passed)
            case "failed": return ("실패 \((s.counts["failed"] ?? 0) + (s.counts["error"] ?? 0))", .failed)
            case .some: return ("확인 필요", .attention)
            case nil:
                switch s.state {
                case "collection_error": return ("수집 오류", .failed)
                case "no_tests": return ("테스트 없음", .attention)
                case "interrupted": return ("중단됨", .attention)
                case "incomplete": return ("미완료", .attention)
                default: return (s.title, .attention)
                }
            }
        case .incomplete(_, let stopped, _, _): return (stopped ? "미완료 · 중지함" : "미완료", .attention)
        case .collectionFailed: return ("수집 실패", .failed)
        case .aggregationFailed, .eventsMixed: return ("집계 오류", .failed)
        case .launchFailed: return ("실행 오류", .failed)
        }
    }

    /// 끝난 실행의 진행 값(끝난 수, 수집 수). 집계 결과나 미완료 기록이 없으면 nil.
    static func outcomeProgress(_ outcome: RunOutcome) -> (done: Int, total: Int?)? {
        switch outcome {
        case .finished(let s): return (finishedCount(s.counts), collectedTotal(s.counts))
        case .incomplete(_, _, let done, let total): return (done, total)
        default: return nil
        }
    }

    /// 환경 한 줄을 만든다.
    /// - Parameters:
    ///   - env: 환경 등록 정보.
    ///   - check: 검사 결과. nil이면 검사 중.
    ///   - snapshot: 실행 상태. 앱 전체에서 실행 중인 것이 있으면 다른 환경의 ▶를 끈다.
    ///   - selected: 이 행이 선택됐는지.
    /// 문구 우선순위: 이 환경 실행 중 > 검사 중 > 실행 불가 > 마지막 결과 > 실행 전.
    /// 실행 불가를 마지막 결과보다 앞에 두는 이유: 지금 누를 수 없는 이유가 지난 결과보다 먼저 필요하다
    /// (지난 결과는 상세에서 그대로 볼 수 있다).
    public static func row(env: PMHEnvironment, check: EnvCheck?, snapshot: RunSnapshot, selected: Bool) -> EnvRowModel {
        let versionText = check.map { c in c.pythonVersionText.map { "Python \($0)" } ?? "Python -" } ?? "검사 중"
        var row = EnvRowModel(id: env.id, name: env.name, versionText: versionText, tone: .idle,
                              statusText: "실행 전", progress: nil, indeterminate: false, progressText: nil,
                              action: .run(enabled: false), actionHelp: nil, isSelected: selected)
        if let active = snapshot.active, active.envID == env.id {
            row.tone = .running
            row.action = .stop(enabled: !active.stopping)
            row.actionHelp = active.stopping ? "중지하는 중입니다." : "실행을 중지합니다."
            switch active.phase {
            case .waitingForEvents:
                row.indeterminate = true
            case .running(let done, let total):
                if let total = total, total > 0 {
                    row.progress = min(Double(done) / Double(total), 1)
                    row.progressText = "\(done)/\(total)"
                } else {
                    // 수집이 끝나기 전에는 전체 수를 모른다. 값 없이 움직이는 바로 보여 준다.
                    row.indeterminate = true
                }
            }
            row.statusText = active.stopping ? "중지하는 중…" : active.phase.text
            return row
        }
        let reason = RunEligibility.reason(for: check)
        let busy = snapshot.active != nil
        row.action = .run(enabled: reason == nil && !busy)
        row.actionHelp = reason ?? (busy ? "다른 환경이 실행 중입니다(동시에 1건만 실행)." : "pytest를 실행합니다.")
        if check == nil {
            row.tone = .checking
            row.statusText = "환경 검사 중"
        } else if let reason = reason {
            row.tone = .unavailable
            row.statusText = "실행 불가: \(reason)"
        } else if let outcome = snapshot.results[env.id] {
            let status = outcomeStatus(outcome)
            row.tone = status.tone
            row.statusText = status.text
        }
        // 실행 불가여도 지난 결과의 진행 바는 보여 준다(무엇이 얼마나 돌았는지는 여전히 사실이다).
        if let outcome = snapshot.results[env.id], let p = outcomeProgress(outcome), let total = p.total, total > 0 {
            row.progress = min(Double(p.done) / Double(total), 1)
            row.progressText = "\(p.done)/\(total)"
        }
        return row
    }

    // MARK: 실패 목록

    /// "파일:줄" 문구. 경로가 root 아래면 root 기준 상대 경로로 줄인다.
    /// - Returns: 경로가 없으면 nil. 줄 번호가 없으면 파일만.
    public static func locationText(path: String?, line: Int?, root: String?) -> String? {
        guard let path = path, !path.isEmpty else { return nil }
        var shown = path
        if let root = root, !root.isEmpty {
            // 끝에 "/"를 붙여 비교한다. 붙이지 않으면 "/a/proj"가 "/a/project/x.py"의 앞부분으로 잘못 맞는다.
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { shown = String(path.dropFirst(prefix.count)) }
        }
        return line.map { "\(shown):\($0)" } ?? shown
    }

    /// 실패 목록을 만든다: 수집 오류 먼저, 그다음 failed·error·incomplete 테스트를 집계기가 준 순서대로.
    /// incomplete를 넣는 이유: 일부 단계만 기록된 테스트는 결과가 확정되지 않아 사용자가 확인해야 한다.
    /// skip·xfail은 넣지 않는다(의도한 결과라 원인 확인 대상이 아니다).
    public static func failureEntries(_ summary: RunSummary) -> [FailureEntry] {
        let root = summary.projectRoot
        var entries: [FailureEntry] = []
        for (i, record) in summary.collectionErrors.enumerated() {
            let f = record.failure
            entries.append(FailureEntry(
                id: "collect#\(i)", title: record.nodeid ?? "(수집 대상 불명)", statusLabel: "수집 오류", tone: .failed,
                locationText: locationText(path: f?.path, line: f?.line, root: root),
                summary: f?.message,
                sections: [FailureSection(title: "수집 단계", message: f?.message, detail: f?.detail)]))
        }
        let labels: [String: String] = ["failed": "실패", "error": "오류", "incomplete": "미완료"]
        for test in summary.tests {
            guard let label = labels[test.status] else { continue }
            let failures = test.failures
            var sections = failures.map { FailureSection(title: "\($0.phase) 단계", message: $0.failure.message, detail: $0.failure.detail) }
            var summaryLine = failures.first?.failure.message
            if test.status == "incomplete" {
                let missing = test.missingPhases
                let text = missing.isEmpty
                    ? "판정을 확정하지 못했습니다(이전 형식의 strict xpass 등)."
                    : "기록되지 않은 단계: \(missing.joined(separator: ", ")). 강제 종료 등으로 끊겼을 수 있습니다."
                sections.append(FailureSection(title: "미완료 이유", message: text, detail: nil))
                if summaryLine == nil { summaryLine = text }
            }
            // 실제 실패 위치를 우선한다. 테스트 정의 위치와 다를 수 있고, 원인은 실패 위치에 있다.
            let first = failures.first?.failure
            let location = first?.path != nil
                ? locationText(path: first?.path, line: first?.line, root: root)
                : locationText(path: test.location?.path, line: test.location?.line, root: root)
            let title = test.occurrence > 1 ? "\(test.nodeid) (\(test.occurrence)번째)" : test.nodeid
            entries.append(FailureEntry(id: "\(test.nodeid)#\(test.occurrence)", title: title, statusLabel: label,
                                        tone: test.status == "incomplete" ? .attention : .failed,
                                        locationText: location, summary: summaryLine, sections: sections))
        }
        return entries
    }

    // MARK: 상세

    /// 선택한 환경의 상세를 만든다.
    /// - Parameters:
    ///   - envID: 환경 id.
    ///   - active: 이 환경이 실행 중이면 그 실행. 다른 환경의 실행이면 nil을 넘긴다.
    ///   - outcome: 이 환경의 마지막 결과(없으면 nil).
    ///   - elapsed: 마지막 실행의 소요 시간(초).
    ///   - blockedReason: 실행할 수 없는 이유(RunEligibility). 있으면 안내에 덧붙인다.
    /// 실행 중에는 진행률만 보여 준다. 건수와 판정은 Swift가 세지 않고 끝난 뒤 집계기 결과로 보여 준다
    /// (판정 규칙을 Swift에 옮기지 않는다는 4단계 결정을 따른다).
    public static func detail(envID: String, active: ActiveRun?, outcome: RunOutcome?,
                              elapsed: TimeInterval?, blockedReason: String?) -> EnvDetailModel {
        var model = EnvDetailModel(envID: envID, headline: "아직 실행하지 않았습니다", tone: .idle,
                                   progressRing: emptyRing(caption: "진행"), passRing: emptyRing(caption: "통과율"),
                                   elapsedText: "—", liveStartedAt: nil, counts: [], failures: [], notes: [])
        if let active = active {
            model.headline = active.stopping ? "중지하는 중… (\(active.phase.text))" : active.phase.text
            model.tone = .running
            switch active.phase {
            case .waitingForEvents: model.progressRing = progressRing(done: 0, total: nil)
            case .running(let done, let total): model.progressRing = progressRing(done: done, total: total)
            }
            model.liveStartedAt = active.startedAt
            model.notes = ["건수와 실패 목록은 실행이 끝난 뒤 집계 결과로 보여 줍니다."]
            return model
        }
        if let elapsed = elapsed { model.elapsedText = formatElapsed(elapsed) }
        if let outcome = outcome {
            let status = outcomeStatus(outcome)
            model.tone = status.tone
            switch outcome {
            case .finished(let s):
                model.headline = s.title
                let total = collectedTotal(s.counts)
                model.progressRing = progressRing(done: finishedCount(s.counts), total: total)
                model.passRing = passRing(passed: s.counts["passed"] ?? 0, total: total)
                model.counts = countItems(s.counts)
                model.failures = failureEntries(s)
                if let n = s.counts["not_run"], n > 0 {
                    model.notes.append("미실행 \(n)건: 중지나 -x 등으로 시작하지 못한 테스트입니다.")
                }
            case .incomplete(_, _, let done, let total):
                model.headline = outcome.title
                model.progressRing = progressRing(done: done, total: total)
                model.notes.append("종료 기록이 없어 판정하지 않았습니다(중지·강제 종료 등). 건수는 집계하지 않았습니다.")
            default:
                model.headline = outcome.title
                if let d = outcome.detail { model.notes.append(d) }
            }
        } else {
            model.notes.append("▶를 눌러 실행하세요. 결과는 앱을 다시 시작하면 사라집니다.")
        }
        if let reason = blockedReason { model.notes.append("실행 불가: \(reason)") }
        return model
    }

    // MARK: 팝오버 전체

    /// 팝오버 전체 상태를 만든다.
    /// - Parameters:
    ///   - registry: 등록한 프로젝트·환경.
    ///   - checks: 환경 id → 검사 결과(없으면 검사 중).
    ///   - snapshot: 실행 상태.
    ///   - preferredProjectID·preferredEnvID: 사용자가 고른 값. 없거나 지금 목록에 없으면 기본값을 쓴다.
    /// 기본 선택: 프로젝트는 실행 중인 환경이 있는 프로젝트, 없으면 첫 프로젝트.
    /// 환경은 그 프로젝트에서 실행 중인 환경, 없으면 첫 환경.
    public static func build(registry: Registry, checks: [String: EnvCheck], snapshot: RunSnapshot,
                             preferredProjectID: UUID?, preferredEnvID: String?) -> PopoverState {
        let options = registry.projects.map { ProjectOption(id: $0.id, name: $0.name) }
        var state = PopoverState(projects: options, selectedProjectID: nil, rows: [], selectedEnvID: nil,
                                 detail: nil, emptyMessage: nil)
        guard !registry.projects.isEmpty else {
            state.emptyMessage = "등록한 프로젝트가 없습니다. ⚙에서 \"프로젝트 추가...\"를 고르세요."
            return state
        }
        let activeEnv = snapshot.active?.envID
        let project = registry.projects.first { $0.id == preferredProjectID }
            ?? registry.projects.first { p in p.environments.contains { $0.id == activeEnv } }
            ?? registry.projects[0]
        state.selectedProjectID = project.id
        guard !project.environments.isEmpty else {
            state.emptyMessage = "이 프로젝트에 환경이 없습니다. ⚙에서 \"환경 추가...\"를 고르세요."
            return state
        }
        let env = project.environments.first { $0.id == preferredEnvID }
            ?? project.environments.first { $0.id == activeEnv }
            ?? project.environments[0]
        state.selectedEnvID = env.id
        state.rows = project.environments.map {
            row(env: $0, check: checks[$0.id], snapshot: snapshot, selected: $0.id == env.id)
        }
        let active = snapshot.active?.envID == env.id ? snapshot.active : nil
        // 검사 중(check == nil)은 상세에 따로 적지 않는다. 행 문구가 이미 "환경 검사 중"이다.
        let blocked = checks[env.id].flatMap { RunEligibility.reason(for: $0) }
        state.detail = detail(envID: env.id, active: active, outcome: snapshot.results[env.id],
                              elapsed: snapshot.elapsed[env.id], blockedReason: blocked)
        return state
    }
}
