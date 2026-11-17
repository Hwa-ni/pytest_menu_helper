// NotificationPresentation.swift
// 8단계 완료 알림의 판단과 문구를 만드는 순수 코드. UserNotifications·AppKit을 쓰지 않는다.
// 입력: 등록 정보(Registry), 팝오버·캐릭터와 같은 합친 실행 상태(RunSnapshot.merged의 결과),
// 이미 처리한 실행 ID 집합, [완료 알림] 토글 값, 알림 권한 상태.
// 출력: 실행마다 "보냄(제목·본문·identifier)" 또는 "보내지 않음(이유)" 결정, 팝오버 아래 권한 안내 문장.
// 실제로 알림 센터에 넣는 일과 권한 읽기·요청은 앱 쪽 Notifier(PMHApp/Notifier.swift)가 한다.
// 제목의 결과 문구는 팝오버 행 문구와 같은 함수(ResultPresentation.outcomeStatus)로 만든다.
// 화면마다 같은 결과를 다른 말로 부르면 "알림은 실패인데 팝오버는 미완료" 같은 혼란이 생기기 때문이다.
// 설계 원본: docs/STEP8_DESIGN.md 2절. 결정(2026-11-17): 터미널 실행도 보냄, 중단됨은 보내지 않음,
// 팝오버가 열려 있어도 보냄.

import Foundation

/// 알림 권한 상태. UNAuthorizationStatus를 PMHCore에서 쓸 수 있게 옮긴 값이다(PMHCore는 UserNotifications를 쓰지 않는다).
public enum NotificationAuthorization: String, Equatable {
    /// 사용자가 아직 정하지 않음. 이때만 앱이 권한을 요청한다.
    case notDetermined
    /// 거부됨(시스템 설정에서 꺼짐 포함).
    case denied
    /// 허용됨.
    case authorized
    /// 임시 허용(조용히 알림 센터에만 쌓임). 보내는 데는 문제없다.
    case provisional
    /// App Clip용 임시 허용. 이 앱에서는 나오지 않지만 값 목록을 빠짐없이 옮긴다.
    case ephemeral
    /// 아직 읽지 않았거나 알 수 없는 값(향후 macOS가 새 값을 추가한 경우).
    case unknown

    /// 이 상태에서 알림 센터에 요청을 넣어도 되는지.
    /// notDetermined·unknown을 false로 두는 이유: 넣어도 UNErrorDomain 1(허용 안 됨)로 실패한다(2.5단계 샘플에서 확인).
    public var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied, .unknown: return false
        }
    }
}

/// 보낼 알림 한 건의 내용.
public struct CompletionNotice: Equatable {
    /// 알림 요청 identifier. 실행 ID를 그대로 쓴다. 같은 ID로 다시 넣으면 알림 센터가 덮어써 중복이 생기지 않는다.
    public var identifier: String
    /// 알림을 눌렀을 때 팝오버에서 고를 환경 id.
    public var envID: String
    /// 예: "실패 1 · fastapi_demo / pmh-3.13 · 터미널".
    public var title: String
    /// 예: "통과 4 · 실패 1 · 2.3초\ntest_main.py::test_fail". 둘째 줄은 실패가 있을 때만.
    public var body: String
}

/// 실행 하나에 대한 결정.
public enum NotificationDecision: Equatable {
    /// 보낸다.
    case send(CompletionNotice)
    /// 보내지 않는다. reason은 로그에 그대로 남길 짧은 이유(예: "중단", "완료 알림 꺼짐").
    case skip(runID: String, envID: String, reason: String)

    /// 결정이 가리키는 실행 ID. 처리한 집합에 넣을 때 쓴다.
    public var runID: String {
        switch self {
        case .send(let notice): return notice.identifier
        case .skip(let runID, _, _): return runID
        }
    }
}

/// 완료 알림의 판단·문구 함수 모음. 모두 입력만 보고 결과를 돌려주는 순수 함수다.
public enum NotificationPresentation {
    /// 중단으로 보고 알림을 보내지 않는 이유 문구. 로그 검증에서 이 문구를 찾는다(docs/APP.md 8단계).
    public static let interruptedReason = "중단"
    /// [완료 알림] 토글이 꺼져 있을 때의 이유 문구.
    public static let disabledReason = "완료 알림 꺼짐"
    /// 토글은 켰는데 권한이 거부됐을 때 팝오버 아래에 보일 회색 안내.
    /// 앱 이름은 시스템 설정 알림 목록에 보이는 표시 이름(Info.plist의 CFBundleDisplayName)과 맞춘다.
    public static let deniedNotice = "알림이 꺼져 있습니다. 시스템 설정 > 알림 > pytest Menu Helper에서 허용하세요."

    /// 알림을 보내지 않을 결과면 그 이유, 보낼 결과면 nil.
    /// - Parameter outcome: 실행의 마지막 결과.
    /// 보내지 않는 경우(사용자 결정 2, 2026-11-17): 사용자가 직접 멈춘 실행.
    ///   - 집계 상태가 interrupted: ■ 중지(SIGINT)나 터미널 Ctrl+C로 pytest가 스스로 멈춤을 기록한 경우.
    ///   - 미완료이면서 stopped == true: ■ 중지를 눌렀지만 제시간에 멈추지 않아 앱이 강제로 끝낸 경우.
    ///     결과 문구는 "미완료 · 중지함"이지만 멈추게 한 사람이 사용자 자신이라 이미 안다. 그래서 같이 뺀다.
    /// 외부 kill -9나 터미널 닫힘으로 끝난 미완료(stopped == false)는 예상하지 못한 끝남이라 보낸다.
    public static func skipReason(_ outcome: RunOutcome) -> String? {
        switch outcome {
        case .finished(let s) where s.verdict == nil && s.state == "interrupted": return interruptedReason
        case .incomplete(_, let stopped, _, _) where stopped: return interruptedReason
        default: return nil
        }
    }

    /// 알림 한 건의 제목·본문을 만든다.
    /// - Parameters:
    ///   - runID: 실행 ID(identifier가 된다).
    ///   - project·env: 결과가 난 프로젝트와 환경(이름을 제목에 넣는다).
    ///   - outcome: 마지막 결과.
    ///   - elapsed: 소요 시간(초). 모르면 nil이고 본문에서 시간을 뺀다.
    ///   - source: 결과 출처. 터미널이면 제목 끝에 " · 터미널"을 붙인다(팝오버 행 문구와 같은 표시).
    /// - Returns: 알림 내용. 실패가 없으면 본문은 한 줄이다.
    public static func notice(runID: String, project: Project, env: PMHEnvironment, outcome: RunOutcome,
                              elapsed: TimeInterval?, source: RunSource?) -> CompletionNotice {
        // 행 문구에서 출처 표시를 뺀 앞부분과 같은 말. 출처 표시는 이름 뒤에 붙인다
        // ("실패 1 · 터미널 · fastapi_demo"보다 "실패 1 · fastapi_demo / pmh-3.13 · 터미널"이 읽기 쉽다).
        let head = ResultPresentation.outcomeStatus(outcome).text
        var title = "\(head) · \(project.name) / \(env.name)"
        if source == .terminal { title += " · 터미널" }

        // 첫 줄: 끝난 실행은 건수(팝오버 결과 제목과 같은 countsText), 그 밖에는 결과 제목 전체
        // (예: "미완료 · 시그널 9(KILL) · 3/5 끝남"). 건수가 없는 결과에서 제목 머리말만 남기면 이유가 사라진다.
        var first: String
        switch outcome {
        case .finished(let s): first = s.countsText
        default: first = outcome.title
        }
        if let elapsed = elapsed { first += " · " + ResultPresentation.formatElapsed(elapsed) }

        var lines = [first]
        // 둘째 줄: 첫 실패 테스트 이름과 나머지 수. 팝오버 실패 목록과 같은 함수로 만들어 순서도 같다
        // (수집 오류 먼저, 그다음 보고된 순서). 미완료 항목(주의 색)은 실패가 아니라 넣지 않는다.
        if case .finished(let s) = outcome {
            let failed = ResultPresentation.failureEntries(s).filter { $0.tone == .failed }
            if let top = failed.first {
                lines.append(failed.count > 1 ? "\(top.title) 외 \(failed.count - 1)건" : top.title)
            }
        }
        return CompletionNotice(identifier: runID, envID: env.id, title: title, body: lines.joined(separator: "\n"))
    }

    /// 아직 처리하지 않은 끝난 실행마다 결정을 만든다.
    /// - Parameters:
    ///   - registry: 등록 정보. 등록에 없는 환경의 결과는 무시한다(제거된 환경이면 알릴 대상이 없다).
    ///   - snapshot: 합친 실행 상태. results와 runIDs가 같은 환경 id에 있어야 결정을 만든다.
    ///     실행 ID를 모르는 결과(이전 형식 값)는 한 번만 보낸다는 약속을 지킬 수 없어 보내지 않는다.
    ///   - handled: 이미 보냈거나 보내지 않기로 한 실행 ID. 여기 있으면 다시 결정하지 않는다.
    ///   - enabled: [완료 알림] 토글. 꺼져 있으면 모든 새 결과를 "보내지 않음"으로 결정한다.
    ///     꺼진 동안의 결과도 처리한 것으로 남겨야, 나중에 토글을 켰을 때 지난 결과가 한꺼번에 오지 않는다.
    /// - Returns: 등록 순서(프로젝트, 환경)대로 정렬한 결정. 같은 실행 ID는 한 번만 들어간다.
    public static func decisions(registry: Registry, snapshot: RunSnapshot, handled: Set<String>,
                                 enabled: Bool) -> [NotificationDecision] {
        var result: [NotificationDecision] = []
        var seen = handled
        for project in registry.projects {
            for env in project.environments {
                guard let outcome = snapshot.results[env.id], let runID = snapshot.runIDs[env.id],
                      !seen.contains(runID) else { continue }
                seen.insert(runID)
                if !enabled {
                    result.append(.skip(runID: runID, envID: env.id, reason: disabledReason))
                } else if let reason = skipReason(outcome) {
                    result.append(.skip(runID: runID, envID: env.id, reason: reason))
                } else {
                    result.append(.send(notice(runID: runID, project: project, env: env, outcome: outcome,
                                               elapsed: snapshot.elapsed[env.id], source: snapshot.sources[env.id])))
                }
            }
        }
        return result
    }

    /// 팝오버 아래 권한 안내 문장. 보일 필요가 없으면 nil.
    /// - Parameters: enabled([완료 알림] 토글), authorization(마지막으로 읽은 권한 상태).
    /// 거부(denied)일 때만 보인다. notDetermined는 앱이 곧 요청하는 중이고, unknown은 아직 읽기 전이라
    /// 안내를 띄우면 잠깐 깜빡이는 잘못된 경고가 된다. 토글을 끈 사용자에게는 권한 안내가 필요 없다.
    public static func permissionNotice(enabled: Bool, authorization: NotificationAuthorization) -> String? {
        enabled && authorization == .denied ? deniedNotice : nil
    }
}
