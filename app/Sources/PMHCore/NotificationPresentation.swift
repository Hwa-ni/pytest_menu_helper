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
// 9단계(docs/STEP9_DESIGN.md 3.4, 7절 결정 5): [모두 실행] 묶음(환경 2개 이상)은 다 끝난 뒤 요약 1건만 보낸다.
// 제목 "3개 환경 중 1개 실패 · fastapi_demo", 본문 "pmh-3.9 실패 1 · pmh-3.12 통과 · pmh-3.13 통과".
// 묶음에 든 실행 ID는 모두 처리한 것으로 넣어 낱개 알림이 따로 나가지 않게 한다. 사용자가 ■로 멈춘 환경(대기 취소 포함)은
// "중단됨"으로 요약에 넣고, 모두 멈췄으면 보내지 않는다. 낱개 ▶와 터미널 실행은 8단계 규칙 그대로 1건씩이다.

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
    /// 9단계: 알림을 눌렀을 때 팝오버에서 "환경 비교" 절까지 보여 줄지. 묶음 요약 알림만 true다.
    public var showsComparison: Bool = false
    /// 이 알림으로 처리한 실행 ID 전체. 낱개 알림은 [identifier], 묶음 요약은 묶음 ID와 묶음의 실행 ID 모두.
    /// 비어 있으면 [identifier]로 본다(아래 handledIDs).
    public var coveredRunIDs: [String] = []
}

/// 실행 하나에 대한 결정.
public enum NotificationDecision: Equatable {
    /// 보낸다.
    case send(CompletionNotice)
    /// 보내지 않는다. reason은 로그에 그대로 남길 짧은 이유(예: "중단", "완료 알림 꺼짐").
    /// 9단계 묶음 결정이면 runID는 묶음 ID, covered는 묶음의 실행 ID 전체다(낱개 결정은 빈 목록).
    case skip(runID: String, envID: String, reason: String, covered: [String] = [])

    /// 결정이 가리키는 실행 ID(묶음이면 묶음 ID). 로그에 남기는 값이다.
    public var runID: String {
        switch self {
        case .send(let notice): return notice.identifier
        case .skip(let runID, _, _, _): return runID
        }
    }

    /// 처리한 집합(handled)에 넣을 ID 전체. 낱개는 실행 ID 하나, 묶음은 묶음 ID와 묶음의 실행 ID 전부.
    /// 묶음의 실행 ID까지 넣는 이유: 묶음이 정리된 뒤(RunController.pruneBatchesLocked)에도 그 결과가 남아 있으면
    /// 낱개 규칙이 그 실행을 새 결과로 보고 알림을 한 번 더 보낸다.
    public var handledIDs: [String] {
        switch self {
        case .send(let notice): return [notice.identifier] + notice.coveredRunIDs
        case .skip(let runID, _, _, let covered): return [runID] + covered
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
    /// 9단계 묶음: 묶음 단위로 알릴 묶음(환경 2개 이상)의 실행 ID는 낱개로 결정하지 않는다. 묶음이 끝날 때까지 기다렸다가
    /// 묶음 요약 결정 하나(batchDecisions)로 처리한다. 반환 순서는 낱개 결정(등록 순서) 다음에 묶음 결정(시작 시각 순).
    public static func decisions(registry: Registry, snapshot: RunSnapshot, handled: Set<String>,
                                 enabled: Bool) -> [NotificationDecision] {
        var result: [NotificationDecision] = []
        var seen = handled
        // 묶음이 맡는 실행 ID. 끝나지 않은 묶음의 실행도 넣는다. 먼저 끝난 환경에 낱개 알림이 나가면 "묶음은 요약 1건"이 깨진다.
        let groups = snapshot.batches.filter { isGroup($0.value) }
        let covered = Set(groups.values.flatMap { $0.runIDs.values })
        for project in registry.projects {
            for env in project.environments {
                guard let outcome = snapshot.results[env.id], let runID = snapshot.runIDs[env.id],
                      !seen.contains(runID), !covered.contains(runID) else { continue }
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
        result += batchDecisions(registry: registry, snapshot: snapshot, groups: groups, handled: seen, enabled: enabled)
        return result
    }

    // MARK: 묶음 요약 (9단계)

    /// 묶음 단위로 알릴 묶음인지. 환경이 1개뿐인 묶음은 낱개 알림 규칙을 따른다(요약 "1개 환경 중 0개 실패"보다
    /// 환경 이름과 건수가 보이는 낱개 알림이 더 많은 것을 알려 준다). 캐릭터 규칙(CharacterPresentation.isGroup)과 같다.
    static func isGroup(_ batch: BatchState) -> Bool { batch.envIDs.count >= 2 }

    /// 묶음 요약에 들어갈 환경 한 줄의 상태 문구.
    /// - Returns: 사용자가 멈춘 환경(대기 취소, 집계 interrupted, 미완료 · 중지함)은 "중단됨", 그 밖은 팝오버 행 문구와 같은 말
    ///   (ResultPresentation.outcomeStatus). 이 묶음이 낸 결과가 아니면(다른 실행이 덮어씀) nil.
    static func batchMemberStatus(envID: String, batchID: String, batch: BatchState,
                                  snapshot: RunSnapshot) -> (text: String, stopped: Bool, outcome: RunOutcome?)? {
        if batch.cancelledEnvIDs.contains(envID) { return ("중단됨", true, nil) }
        guard snapshot.batchIDs[envID] == batchID, snapshot.runIDs[envID] == batch.runIDs[envID],
              let outcome = snapshot.results[envID] else { return nil }
        if skipReason(outcome) != nil { return ("중단됨", true, outcome) }
        return (ResultPresentation.outcomeStatus(outcome).text, false, outcome)
    }

    /// 다 끝난 묶음마다 요약 결정 하나를 만든다. 아직 끝나지 않은 묶음은 건너뛴다(다음 상태에서 다시 본다).
    /// - Parameters:
    ///   - groups: 묶음 단위로 알릴 묶음(id → 상태).
    ///   - handled: 이미 처리한 ID(묶음 ID 포함). 묶음 ID가 있으면 다시 결정하지 않는다.
    ///   - enabled: [완료 알림] 토글. 꺼져 있으면 "완료 알림 꺼짐"으로 처리만 한다.
    /// 제목: 실패(넘어진 포즈 조건, CharacterPresentation.pose == .failure)가 있으면 "3개 환경 중 1개 실패 · 프로젝트",
    ///   모두 통과면 "3개 환경 통과 · 프로젝트", 그 밖은 "3개 환경 중 2개 통과 · 프로젝트".
    ///   실패를 캐릭터와 같은 기준으로 세는 이유: 알림은 "실패"인데 캐릭터는 갸웃이면 같은 결과를 다르게 부르게 된다.
    /// 본문: 묶음에 넣은 순서대로 "pmh-3.9 실패 1 · pmh-3.12 통과 · pmh-3.13 중단됨".
    /// 누르면 실패한 첫 환경(없으면 통과가 아닌 첫 환경, 그것도 없으면 첫 환경)과 환경 비교 절을 보인다.
    static func batchDecisions(registry: Registry, snapshot: RunSnapshot, groups: [String: BatchState],
                               handled: Set<String>, enabled: Bool) -> [NotificationDecision] {
        var envIndex: [String: (project: Project, env: PMHEnvironment)] = [:]
        for project in registry.projects { for env in project.environments where envIndex[env.id] == nil {
            envIndex[env.id] = (project, env)
        } }
        var result: [NotificationDecision] = []
        let ordered = groups.sorted { ($0.value.startedAt, $0.key) < ($1.value.startedAt, $1.key) }
        for (batchID, batch) in ordered where batch.isFinished && !handled.contains(batchID) {
            // 등록에서 빠진 환경은 요약에서 뺀다(알릴 대상이 없다). 모두 빠졌으면 결정하지 않는다(낱개 규칙과 같다).
            let members = batch.envIDs.filter { envIndex[$0] != nil }
            guard let firstEnv = members.first, let projectEntry = envIndex[firstEnv] else { continue }
            let project = registry.projects.first { $0.path == batch.projectPath } ?? projectEntry.project
            let covered = batch.envIDs.compactMap { batch.runIDs[$0] }
            let lines = members.compactMap { envID -> (envID: String, name: String, text: String, stopped: Bool,
                                                         outcome: RunOutcome?)? in
                guard let status = batchMemberStatus(envID: envID, batchID: batchID, batch: batch, snapshot: snapshot)
                else { return nil }
                return (envID, envIndex[envID]!.env.name, status.text, status.stopped, status.outcome)
            }
            if !enabled {
                result.append(.skip(runID: batchID, envID: firstEnv, reason: disabledReason, covered: covered))
                continue
            }
            // 모두 사용자가 멈췄으면 보내지 않는다(8단계 결정 2와 같은 이유: 멈춘 사람이 이미 안다).
            // 이 묶음 결과가 하나도 남지 않은 경우(모두 다른 실행으로 바뀜)도 요약할 것이 없어 보내지 않는다.
            if lines.allSatisfy(\.stopped) {
                result.append(.skip(runID: batchID, envID: firstEnv, reason: interruptedReason, covered: covered))
                continue
            }
            let poses = lines.map { $0.outcome.map(CharacterPresentation.pose(for:)) }
            let total = lines.count
            let failed = poses.filter { $0 == .failure }.count
            let passed = poses.filter { $0 == .success }.count
            let head: String
            if failed > 0 { head = "\(total)개 환경 중 \(failed)개 실패" }
            else if passed == total { head = "\(total)개 환경 통과" }
            else { head = "\(total)개 환경 중 \(passed)개 통과" }
            let focus = zip(lines, poses).first { $0.1 == .failure }?.0.envID
                ?? zip(lines, poses).first { $0.1 != .success }?.0.envID
                ?? firstEnv
            let body = lines.map { "\($0.name) \($0.text)" }.joined(separator: " · ")
            result.append(.send(CompletionNotice(identifier: batchID, envID: focus, title: "\(head) · \(project.name)",
                                                 body: body, showsComparison: true, coveredRunIDs: covered)))
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
