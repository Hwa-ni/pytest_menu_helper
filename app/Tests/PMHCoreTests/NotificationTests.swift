// NotificationTests.swift
// 8단계 완료 알림의 판단·문구(NotificationPresentation)와 프로젝트 폴더 없음 검사(ProjectFolderCheck)를 검사한다.
// 알림 센터와 시스템 설정 화면은 자동으로 확인할 수 없으므로, 앱이 그대로 쓰는 결정 값(보낼지, 제목, 본문,
// identifier, 안내 문장, 폴더 오류)을 여기서 고정한다. 실제 알림 표시는 docs/APP.md 8단계 체크리스트로 확인한다.

import Foundation
import Testing
@testable import PMHCore

/// 집계기 판정 결과 하나를 만든다. 실패 테스트를 넣으면 tests 목록에도 그 테스트가 들어간다.
private func finished(state: String = "completed", verdict: String?, counts: [String: Int],
                      failedTests: [String] = [], collectionErrors: [String] = []) -> RunOutcome {
    let tests = failedTests.map { TestResult(nodeid: $0, status: "failed",
                                             phases: ["call": PhaseReport(outcome: "failed", failure: FailureInfo(message: "AssertionError"))]) }
    let errors = collectionErrors.map { CollectionErrorRecord(nodeid: $0, failure: FailureInfo(message: "ImportError")) }
    return .finished(RunSummary(state: state, verdict: verdict, exitCode: verdict == "passed" ? 0 : 1, counts: counts,
                                tests: tests, collectionErrors: errors))
}

private let envA = PMHEnvironment(id: "env-a", name: "pmh-3.13", pythonPath: "/v/pmh-3.13/bin/python")
private let envB = PMHEnvironment(id: "env-b", name: "pmh-3.12", pythonPath: "/v/pmh-3.12/bin/python")
private let projectID = UUID()
private let project = Project(id: projectID, path: "/w/slow_demo", environments: [envA, envB])
private let registry = Registry(projects: [project])

/// 환경 A에 결과 하나가 있는 앱 실행 상태.
private func snapshot(_ outcome: RunOutcome, runID: String = "run-1", elapsed: TimeInterval? = 9.94) -> RunSnapshot {
    var s = RunSnapshot(results: [envA.id: outcome], elapsed: elapsed.map { [envA.id: $0] } ?? [:])
    s.runIDs[envA.id] = runID
    return s
}

@Suite struct NotificationDecisionTests {
    @Test func passedRunSendsOneNoticeWithRunIDAsIdentifier() {
        let s = snapshot(finished(verdict: "passed", counts: ["passed": 5]))
        let d = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true)
        #expect(d.count == 1)
        guard case .send(let n) = d.first else { Issue.record("보내야 함"); return }
        #expect(n.identifier == "run-1")
        #expect(n.envID == envA.id)
        #expect(n.title == "통과 · slow_demo / pmh-3.13")
        #expect(n.body == "통과 5 · 실패 0 · 9.9초")
    }

    /// 같은 실행 ID는 다시 결정하지 않는다. 진행 갱신마다 불려도 실행당 1건이다.
    @Test func sameRunIsDecidedOnlyOnce() {
        let s = snapshot(finished(verdict: "passed", counts: ["passed": 5]))
        let first = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true)
        let handled = Set(first.map(\.runID))
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: handled, enabled: true).isEmpty)
        // 같은 환경에 새 실행 결과가 오면 그 실행은 새로 보낸다.
        let next = snapshot(finished(verdict: "failed", counts: ["passed": 4, "failed": 1], failedTests: ["t.py::bad"]), runID: "run-2")
        let d = NotificationPresentation.decisions(registry: registry, snapshot: next, handled: handled, enabled: true)
        #expect(d.map(\.runID) == ["run-2"])
    }

    /// 실패: 제목은 팝오버 행 문구와 같은 말("실패 2", 실패+오류), 본문 둘째 줄은 첫 실패와 나머지 수.
    @Test func failedRunTitleMatchesRowTextAndBodyNamesFirstFailure() {
        let outcome = finished(verdict: "failed", counts: ["passed": 3, "failed": 2, "error": 1],
                               failedTests: ["test_main.py::test_fail", "test_main.py::test_b"],
                               collectionErrors: [])
        let s = snapshot(outcome, elapsed: 2.34)
        let row = ResultPresentation.row(env: envA, check: EnvCheck(status: .ready, report: nil, issues: []),
                                         snapshot: s, selected: false)
        guard case .send(let n) = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true).first
        else { Issue.record("보내야 함"); return }
        #expect(row.statusText == "실패 3")
        #expect(n.title == "\(row.statusText) · slow_demo / pmh-3.13")
        #expect(n.body == "통과 3 · 실패 2 · 오류 1 · 2.3초\ntest_main.py::test_fail 외 1건")
    }

    /// 실패가 1건이면 "외 N건"을 붙이지 않는다. 수집 오류는 실패 목록 맨 앞이다(팝오버와 같은 순서).
    @Test func collectionErrorComesFirstAndSingleFailureHasNoSuffix() {
        let one = snapshot(finished(verdict: "failed", counts: ["failed": 1], failedTests: ["t.py::only"]))
        guard case .send(let a) = NotificationPresentation.decisions(registry: registry, snapshot: one, handled: [], enabled: true).first
        else { Issue.record("보내야 함"); return }
        #expect(a.body.hasSuffix("\nt.py::only"))
        let collect = snapshot(finished(state: "collection_error", verdict: nil, counts: [:], collectionErrors: ["broken.py"]))
        guard case .send(let b) = NotificationPresentation.decisions(registry: registry, snapshot: collect, handled: [], enabled: true).first
        else { Issue.record("보내야 함"); return }
        #expect(b.title == "수집 오류 · slow_demo / pmh-3.13")
        #expect(b.body.hasSuffix("\nbroken.py"))
    }

    /// 중단됨(■ 중지 SIGINT, 터미널 Ctrl+C)과 "미완료 · 중지함"(■ 뒤 강제 종료)은 보내지 않는다(결정 2).
    @Test func interruptedAndUserStoppedRunsAreSkipped() {
        let interrupted = snapshot(finished(state: "interrupted", verdict: nil, counts: ["passed": 2, "not_run": 3]))
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: interrupted, handled: [], enabled: true)
                == [.skip(runID: "run-1", envID: envA.id, reason: "중단")])
        let stopped = snapshot(.incomplete(termination: .signal(9), stopped: true, done: 2, total: 5))
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: stopped, handled: [], enabled: true)
                == [.skip(runID: "run-1", envID: envA.id, reason: "중단")])
    }

    /// 외부 kill -9로 끝난 미완료는 예상하지 못한 끝남이라 보낸다. 본문에 이유(시그널)와 진행을 그대로 담는다.
    @Test func killedIncompleteRunIsSent() {
        let s = snapshot(.incomplete(termination: .signal(9), stopped: false, done: 2, total: 5), elapsed: 4.0)
        guard case .send(let n) = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true).first
        else { Issue.record("보내야 함"); return }
        #expect(n.title == "미완료 · slow_demo / pmh-3.13")
        #expect(n.body == "미완료 · 시그널 9(KILL) · 2/5 끝남 · 4.0초")
    }

    /// 확인 필요(skip만)와 테스트 없음도 보낸다(설계 2.1 표).
    @Test func attentionAndNoTestsAreSent() {
        let skipped = snapshot(finished(verdict: "attention", counts: ["skipped": 2]))
        let noTests = snapshot(finished(state: "no_tests", verdict: nil, counts: [:]), elapsed: nil)
        for (s, head) in [(skipped, "확인 필요"), (noTests, "테스트 없음")] {
            guard case .send(let n) = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true).first
            else { Issue.record("보내야 함: \(head)"); continue }
            #expect(n.title.hasPrefix(head + " · "))
        }
        // 시간을 모르면 본문에 시간을 넣지 않는다.
        if case .send(let n) = NotificationPresentation.decisions(registry: registry, snapshot: noTests, handled: [], enabled: true).first {
            #expect(n.body == "통과 0 · 실패 0")
        }
    }

    /// 토글을 끄면 보내지 않지만 처리한 것으로 남긴다. 나중에 켜도 지난 결과가 오지 않는다.
    @Test func disabledToggleSkipsAndMarksHandled() {
        let s = snapshot(finished(verdict: "passed", counts: ["passed": 1]))
        let off = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: false)
        #expect(off == [.skip(runID: "run-1", envID: envA.id, reason: "완료 알림 꺼짐")])
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: Set(off.map(\.runID)), enabled: true).isEmpty)
    }

    /// 터미널 실행 결과(merged로 합쳐진 값)는 제목 끝에 " · 터미널"을 붙이고 외부 실행 ID를 identifier로 쓴다.
    @Test func terminalResultUsesExternalRunIDAndSuffix() {
        let ext = ExternalSnapshot(results: [envB.id: ExternalResult(
            runID: "ext-9", envID: envB.id, outcome: finished(verdict: "passed", counts: ["passed": 5]),
            elapsed: 10.2, finishedAt: Date(timeIntervalSince1970: 100))])
        let merged = RunSnapshot().merged(external: ext)
        #expect(merged.runIDs[envB.id] == "ext-9")
        guard case .send(let n) = NotificationPresentation.decisions(registry: registry, snapshot: merged, handled: [], enabled: true).first
        else { Issue.record("보내야 함"); return }
        #expect(n.identifier == "ext-9")
        #expect(n.title == "통과 · slow_demo / pmh-3.12 · 터미널")
        #expect(n.body == "통과 5 · 실패 0 · 10초")
        // 팝오버 행 문구("통과 · 터미널")와 머리말·출처 표시가 같다.
        let row = ResultPresentation.row(env: envB, check: EnvCheck(status: .ready, report: nil, issues: []),
                                         snapshot: merged, selected: false)
        #expect(row.statusText == "통과 · 터미널")
    }

    /// 앱 결과가 더 최근이면 merged가 앱 결과와 앱 실행 ID를 남긴다(터미널 실행 ID가 섞이지 않는다).
    @Test func mergedKeepsAppRunIDWhenAppResultIsNewer() {
        var app = snapshot(finished(verdict: "passed", counts: ["passed": 1]), runID: "app-1")
        app.finishedAt[envA.id] = Date(timeIntervalSince1970: 200)
        let ext = ExternalSnapshot(results: [envA.id: ExternalResult(
            runID: "ext-1", envID: envA.id, outcome: finished(verdict: "failed", counts: ["failed": 1]),
            elapsed: 1, finishedAt: Date(timeIntervalSince1970: 100))])
        #expect(app.merged(external: ext).runIDs[envA.id] == "app-1")
    }

    /// 실행 ID를 모르는 결과와 등록에 없는 환경의 결과는 결정하지 않는다.
    @Test func resultsWithoutRunIDOrUnregisteredEnvAreIgnored() {
        var s = RunSnapshot(results: [envA.id: finished(verdict: "passed", counts: ["passed": 1])])
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true).isEmpty)
        s.results["gone"] = finished(verdict: "passed", counts: ["passed": 1])
        s.runIDs["gone"] = "run-x"
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true).isEmpty)
    }

    /// 권한 안내는 토글 켜짐 + 거부일 때만.
    @Test func permissionNoticeOnlyWhenEnabledAndDenied() {
        #expect(NotificationPresentation.permissionNotice(enabled: true, authorization: .denied) == NotificationPresentation.deniedNotice)
        for status: NotificationAuthorization in [.authorized, .provisional, .notDetermined, .unknown] {
            #expect(NotificationPresentation.permissionNotice(enabled: true, authorization: status) == nil)
        }
        #expect(NotificationPresentation.permissionNotice(enabled: false, authorization: .denied) == nil)
        #expect(NotificationAuthorization.authorized.allowsDelivery)
        #expect(!NotificationAuthorization.denied.allowsDelivery)
        #expect(!NotificationAuthorization.notDetermined.allowsDelivery)
    }
}

@Suite struct ProjectFolderTests {
    /// 폴더가 아닌(없거나 파일로 바뀐) 프로젝트만 고른다.
    @Test func missingReturnsProjectsWhoseFolderIsGone() {
        let other = Project(path: "/w/fastapi_demo")
        let reg = Registry(projects: [project, other])
        let missing = ProjectFolderCheck.missing(reg) { $0 == "/w/fastapi_demo" }
        #expect(missing == [projectID])
    }

    /// 실제 파일 시스템: 임시 폴더를 등록한 뒤 이름을 바꾸면 없는 것으로 나온다.
    @Test func renamedTemporaryFolderIsDetected() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pmh-folder-\(UUID().uuidString)")
        let renamed = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-renamed")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base); try? fm.removeItem(at: renamed) }
        let p = Project(path: base.path)
        let reg = Registry(projects: [p])
        let isDir: (String) -> Bool = { path in
            var d: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
        }
        #expect(ProjectFolderCheck.missing(reg, isDirectory: isDir).isEmpty)
        try fm.moveItem(at: base, to: renamed)
        #expect(ProjectFolderCheck.missing(reg, isDirectory: isDir) == [p.id])
    }

    /// 팝오버 상태: 선택한 프로젝트의 폴더가 없으면 프로젝트 줄 오류. 환경이 없는 프로젝트에서도 보인다.
    @Test func popoverStateShowsFolderErrorForSelectedProject() {
        let state = ResultPresentation.build(registry: registry, checks: [:], snapshot: RunSnapshot(),
                                             preferredProjectID: nil, preferredEnvID: nil, missingFolders: [projectID])
        #expect(state.projectFolderError == "프로젝트 폴더가 없습니다")
        #expect(state.rows.count == 2) // 환경 행은 그대로 보인다
        let empty = Project(path: "/w/empty")
        let reg = Registry(projects: [empty])
        let s2 = ResultPresentation.build(registry: reg, checks: [:], snapshot: RunSnapshot(),
                                          preferredProjectID: nil, preferredEnvID: nil, missingFolders: [empty.id])
        #expect(s2.projectFolderError != nil)
        let fine = ResultPresentation.build(registry: registry, checks: [:], snapshot: RunSnapshot(),
                                            preferredProjectID: nil, preferredEnvID: nil)
        #expect(fine.projectFolderError == nil)
    }

    /// 다시 지정: 경로만 바뀌고 프로젝트 id·환경 등록은 그대로다.
    @Test func relocateKeepsEnvironments() {
        guard case .relocated(let next) = ProjectFolderCheck.relocate(registry, projectID: projectID, to: "/w/slow_demo2")
        else { Issue.record("바뀌어야 함"); return }
        #expect(next.projects[0].path == "/w/slow_demo2")
        #expect(next.projects[0].id == projectID)
        #expect(next.projects[0].environments == [envA, envB])
    }

    /// 다른 프로젝트가 쓰는 폴더로는 바꾸지 않는다. 없는 프로젝트도 막는다. 자기 경로 그대로는 허용.
    @Test func relocateRejectsDuplicateAndUnknown() {
        let other = Project(path: "/w/fastapi_demo")
        let reg = Registry(projects: [project, other])
        #expect(ProjectFolderCheck.relocate(reg, projectID: projectID, to: "/w/fastapi_demo")
                == .rejected(ProjectFolderCheck.duplicateMessage))
        if case .relocated = ProjectFolderCheck.relocate(reg, projectID: UUID(), to: "/x") { Issue.record("막아야 함") }
        #expect(ProjectFolderCheck.relocate(reg, projectID: projectID, to: "/w/slow_demo") == .relocated(reg))
    }
}
