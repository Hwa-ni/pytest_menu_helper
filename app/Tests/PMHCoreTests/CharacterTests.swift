// CharacterTests.swift
// 7단계 캐릭터 단위 테스트.
// 대상: 결과 → 포즈 대응(CharacterPresentation.pose), 여러 환경 중 따를 상태 고르기(CharacterPresentation.state),
//       창 위치 규칙(CharacterPlacement), 캐릭터 페이지와 포즈 스크립트(CharacterPage).
// 핵심 고정 사항: 성공 포즈는 집계기 verdict "passed"에서만 나오고, 테스트 없음·중단·미완료·skip·
// 집계/실행 오류는 성공 포즈를 쓰지 않는다. 앱 ▶ 실행과 터미널 실행이 같은 규칙(merged 상태)을 따른다.

import CoreGraphics
import Foundation
import Testing
@testable import PMHCore

// MARK: 도움 함수

/// 집계기 판정 하나를 결과 값으로 만든다.
private func finished(state: String = "completed", verdict: String?, counts: [String: Int] = [:]) -> RunOutcome {
    .finished(RunSummary(state: state, verdict: verdict, exitCode: nil, counts: counts))
}

/// 환경 두 개(a, b)를 가진 프로젝트 하나.
private func twoEnvRegistry() -> Registry {
    Registry(projects: [Project(path: "/work/proj", environments: [
        PMHEnvironment(id: "a", name: "pmh-3.13", pythonPath: "/venvs/a/bin/python"),
        PMHEnvironment(id: "b", name: "pmh-3.12", pythonPath: "/venvs/b/bin/python"),
    ])])
}

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// 문제없는 환경 검사 결과. 행 문구가 "실행 불가"가 아니라 마지막 결과를 보여 주게 한다.
private func readyCheck() -> EnvCheck { EnvCheck(status: .ready, report: nil, issues: []) }

private func external(_ envID: String, run: String, started: TimeInterval, known: Bool = true) -> ExternalActive {
    ExternalActive(runID: run, envID: envID, projectID: UUID(), phase: .running(done: 1, total: 5),
                   startedAt: t(started), pid: 42, statusKnown: known)
}

// MARK: 결과 → 포즈

@Suite struct CharacterPoseTests {
    @Test func passedVerdictIsTheOnlySuccess() {
        #expect(CharacterPresentation.pose(for: finished(verdict: "passed", counts: ["passed": 5])) == .success)
    }

    @Test func failedVerdictAndCollectionErrorFallDown() {
        #expect(CharacterPresentation.pose(for: finished(verdict: "failed")) == .failure)
        #expect(CharacterPresentation.pose(for: finished(state: "collection_error", verdict: nil)) == .failure)
    }

    /// 별도 상태는 갸웃 포즈를 쓴다.
    @Test func separateStatesUseAttention() {
        let outcomes: [RunOutcome] = [
            finished(state: "no_tests", verdict: nil), finished(state: "interrupted", verdict: nil),
            finished(state: "incomplete", verdict: nil), finished(verdict: "attention", counts: ["skipped": 2]),
            .incomplete(termination: .unknown, stopped: false, done: 2, total: 5),
            .incomplete(termination: .signal(9), stopped: true, done: 0, total: nil),
            .collectionFailed(termination: .exit(4), logTail: nil),
            .aggregationFailed(message: "x"), .eventsMixed(foreign: 3), .launchFailed(message: "x"),
            // 집계기에 새 상태 값이 생겨도 성공 동작이 나오지 않는다.
            finished(state: "something_new", verdict: nil),
        ]
        for outcome in outcomes {
            #expect(CharacterPresentation.pose(for: outcome) == .attention, "\(outcome)")
        }
    }

    /// passed 외의 어떤 판정도 성공 포즈가 아니다.
    @Test func noOtherOutcomeIsSuccess() {
        let outcomes: [RunOutcome] = [
            finished(verdict: "failed"), finished(verdict: "attention"),
            finished(state: "no_tests", verdict: nil), finished(state: "interrupted", verdict: nil),
            finished(state: "incomplete", verdict: nil), finished(state: "collection_error", verdict: nil),
            .incomplete(termination: .exit(0), stopped: false, done: 5, total: 5),
            .collectionFailed(termination: .exit(0), logTail: "x"),
            .aggregationFailed(message: ""), .eventsMixed(foreign: 1), .launchFailed(message: ""),
        ]
        for outcome in outcomes {
            #expect(CharacterPresentation.pose(for: outcome) != .success, "\(outcome)")
        }
    }

    @Test func assetNamesMatchFiles() {
        #expect(CharacterPose.idle.assetName == "mascot-fox")
        #expect(CharacterPose.running.assetName == "mascot-fox-animated")
        #expect(CharacterPose.success.assetName == "mascot-fox-success")
        #expect(CharacterPose.failure.assetName == "mascot-fox-error")
        #expect(CharacterPose.attention.assetName == "mascot-fox-attention")
    }
}

// MARK: 상태 글씨(모든 포즈, 행 문구와 같음)

@Suite struct CharacterLabelTests {
    /// 끝난 결과의 글씨는 포즈마다 행 문구(ResultPresentation.row의 statusText)와 같다.
    @Test func resultLabelsMatchRowText() {
        let cases: [(RunOutcome, String)] = [
            (finished(verdict: "passed", counts: ["passed": 5]), "통과"),
            (finished(verdict: "failed", counts: ["passed": 1, "failed": 1]), "실패 1"),
            (finished(verdict: "failed", counts: ["failed": 2, "error": 1]), "실패 3"),
            (finished(state: "collection_error", verdict: nil), "수집 오류"),
            (finished(state: "no_tests", verdict: nil), "테스트 없음"),
            (finished(state: "interrupted", verdict: nil), "중단됨"),
            (finished(state: "incomplete", verdict: nil), "미완료"),
            (finished(verdict: "attention", counts: ["skipped": 2]), "확인 필요"),
            (.incomplete(termination: .unknown, stopped: false, done: 2, total: 5), "미완료"),
            (.incomplete(termination: .signal(9), stopped: true, done: 0, total: nil), "미완료 · 중지함"),
            (.collectionFailed(termination: .exit(4), logTail: nil), "수집 실패"),
            (.aggregationFailed(message: "x"), "집계 오류"),
            (.eventsMixed(foreign: 3), "집계 오류"),
            (.launchFailed(message: "x"), "실행 오류"),
        ]
        let registry = twoEnvRegistry()
        let env = registry.projects[0].environments[0]
        for (outcome, text) in cases {
            for source in [RunSource?.none, .terminal] {
                var snap = RunSnapshot(results: ["a": outcome])
                snap.finishedAt["a"] = t(10)
                if let source = source { snap.sources["a"] = source }
                let s = CharacterPresentation.state(registry: registry, snapshot: snap)
                let expected = source == .terminal ? "\(text) · 터미널" : text
                #expect(s.label == expected, "\(outcome) \(String(describing: source))")
                // 행 문구와 같은지 직접 비교한다(검사 결과가 준비된 환경이라 행은 마지막 결과를 보여 준다).
                let row = ResultPresentation.row(env: env, check: readyCheck(), snapshot: snap, selected: false)
                #expect(s.label == row.statusText, "\(outcome)")
            }
        }
    }

    @Test func idleLabelIsBeforeRun() {
        #expect(CharacterState.idle.label == "실행 전")
    }

    /// 실행 중 글씨: 앱 실행은 "수집 대기"·"실행 중 2/5"·"중지하는 중…", 터미널은 "터미널 실행 중 2/5".
    @Test func runningLabelsMatchRowText() {
        let registry = twoEnvRegistry()
        var active = ActiveRun(runID: "r", envID: "a", projectPath: "/work/proj", phase: .waitingForEvents,
                               stopping: false, startedAt: t(1))
        #expect(CharacterPresentation.state(registry: registry, snapshot: RunSnapshot(actives: [active.envID: active])).label == "수집 대기")
        active.phase = .running(done: 2, total: 5)
        #expect(CharacterPresentation.state(registry: registry, snapshot: RunSnapshot(actives: [active.envID: active])).label == "실행 중 2/5")
        active.stopping = true
        #expect(CharacterPresentation.state(registry: registry, snapshot: RunSnapshot(actives: [active.envID: active])).label == "중지하는 중…")
        let ext = RunSnapshot().merged(external: ExternalSnapshot(active: [external("b", run: "x", started: 5)]))
        #expect(CharacterPresentation.state(registry: registry, snapshot: ext).label == "터미널 실행 중 1/5")
        let unknown = RunSnapshot().merged(external: ExternalSnapshot(active: [external("b", run: "x", started: 5, known: false)]))
        #expect(CharacterPresentation.state(registry: registry, snapshot: unknown).label == "터미널 실행 · 상태 확인 불가 (1/5)")
    }

    /// 진행 글씨가 바뀌어도 key는 그대로다(달리기 애니메이션을 처음부터 다시 재생하지 않는다).
    @Test func progressChangesLabelButNotKey() {
        let registry = twoEnvRegistry()
        var e = external("a", run: "x1", started: 5)
        let first = CharacterPresentation.state(registry: registry, snapshot: RunSnapshot().merged(external: ExternalSnapshot(active: [e])))
        e.phase = .running(done: 3, total: 5)
        let second = CharacterPresentation.state(registry: registry, snapshot: RunSnapshot().merged(external: ExternalSnapshot(active: [e])))
        #expect(first.label == "터미널 실행 중 1/5")
        #expect(second.label == "터미널 실행 중 3/5")
        #expect(first.key == second.key)
        #expect(first.pose == .running && second.pose == .running)
    }
}

// MARK: 따를 상태 고르기

@Suite struct CharacterStateTests {
    @Test func nothingIsIdle() {
        #expect(CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: RunSnapshot()) == .idle)
        #expect(CharacterPresentation.state(registry: Registry(), snapshot: RunSnapshot()) == .idle)
    }

    /// 앱 ▶ 실행 중이면 달리기. 수집 대기여도 달린다.
    @Test func appRunIsRunning() {
        let active = ActiveRun(runID: "r1", envID: "a", projectPath: "/work/proj", phase: .waitingForEvents,
                               stopping: false, startedAt: t(10))
        let s = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: RunSnapshot(actives: [active.envID: active]))
        #expect(s.pose == .running)
        #expect(s.envID == "a")
        #expect(s.key == "run:r1")
        #expect(s.help == "pmh-3.13 · 수집 대기")
        #expect(s.label == "수집 대기")
    }

    /// 터미널 실행도 merged 상태를 거쳐 같은 달리기가 된다.
    @Test func terminalRunIsRunningThroughMerged() {
        let merged = RunSnapshot().merged(external: ExternalSnapshot(active: [external("b", run: "x1", started: 10)]))
        let s = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: merged)
        #expect(s.pose == .running)
        #expect(s.envID == "b")
        #expect(s.help == "pmh-3.12 · 터미널 실행 중 1/5")
    }

    /// 실행 중인 것이 여럿이면 가장 나중에 시작한 실행을 따른다.
    @Test func latestStartedRunWins() {
        let active = ActiveRun(runID: "r1", envID: "a", projectPath: "/work/proj", phase: .running(done: 0, total: 5),
                               stopping: false, startedAt: t(10))
        let later = RunSnapshot(actives: [active.envID: active]).merged(external: ExternalSnapshot(active: [external("b", run: "x1", started: 20)]))
        #expect(CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: later).envID == "b")
        let earlier = RunSnapshot(actives: [active.envID: active]).merged(external: ExternalSnapshot(active: [external("b", run: "x1", started: 5)]))
        #expect(CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: earlier).envID == "a")
    }

    /// 실행 중이면 더 나중에 끝난 결과가 있어도 달리기가 이긴다.
    @Test func runningBeatsNewerResult() {
        var snap = RunSnapshot(results: ["b": finished(verdict: "failed")])
        snap.finishedAt["b"] = t(100)
        snap = snap.merged(external: ExternalSnapshot(active: [external("a", run: "x1", started: 10)]))
        let s = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap)
        #expect(s.pose == .running)
        #expect(s.envID == "a")
    }

    /// 실행이 없으면 모든 등록 환경 중 가장 나중에 끝난 결과.
    @Test func latestFinishedResultWins() {
        var snap = RunSnapshot(results: ["a": finished(verdict: "passed", counts: ["passed": 5]),
                                         "b": finished(verdict: "failed", counts: ["passed": 1, "failed": 1])])
        snap.finishedAt = ["a": t(50), "b": t(40)]
        let s = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap)
        #expect(s.pose == .success)
        #expect(s.envID == "a")
        #expect(s.help == "pmh-3.13 · 통과")
        snap.finishedAt["b"] = t(60)
        let s2 = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap)
        #expect(s2.pose == .failure)
        #expect(s2.envID == "b")
        #expect(s2.help == "pmh-3.12 · 실패 1")
    }

    /// 터미널 결과는 도움말에 출처를 붙이고, 나중에 끝난 쪽이 앱 결과를 이긴다(merged 규칙 그대로).
    @Test func terminalResultFollowsMergedRule() {
        var app = RunSnapshot(results: ["a": finished(verdict: "passed", counts: ["passed": 5])])
        app.finishedAt["a"] = t(10)
        let ext = ExternalSnapshot(results: ["a": ExternalResult(
            runID: "x", envID: "a", outcome: .incomplete(termination: .unknown, stopped: false, done: 2, total: 5),
            elapsed: nil, finishedAt: t(20))])
        let s = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: app.merged(external: ext))
        #expect(s.pose == .attention)
        #expect(s.label == "미완료 · 터미널")
        #expect(s.help == "pmh-3.13 · 미완료 · 터미널")
    }

    /// 등록에서 빠진 환경의 결과는 따르지 않는다.
    @Test func unregisteredEnvironmentIgnored() {
        var snap = RunSnapshot(results: ["gone": finished(verdict: "failed")])
        snap.finishedAt["gone"] = t(99)
        #expect(CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap) == .idle)
        let active = ActiveRun(runID: "r", envID: "gone", projectPath: "/x", phase: .waitingForEvents, stopping: false)
        #expect(CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: RunSnapshot(actives: [active.envID: active])) == .idle)
    }

    /// 상태 확인 불가 터미널 실행은 달리기가 아니라 갸웃 포즈다. 그보다 나중에 끝난 결과가 있으면 결과를 따른다.
    @Test func unknownStatusRunIsAttention() {
        let ext = ExternalSnapshot(active: [external("a", run: "old", started: 30, known: false)])
        let s = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: RunSnapshot().merged(external: ext))
        #expect(s.pose == .attention)
        #expect(s.label == "터미널 실행 · 상태 확인 불가 (1/5)")
        #expect(s.key == "unknown:old")
        var snap = RunSnapshot(results: ["b": finished(verdict: "passed", counts: ["passed": 1])])
        snap.finishedAt["b"] = t(40)
        #expect(CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap.merged(external: ext)).pose == .success)
    }

    /// key: 같은 상태면 같고, 같은 환경의 새 결과면 달라진다(넘어지는 동작을 새 결과에서만 다시 재생).
    @Test func keyChangesOnlyForNewResult() {
        var snap = RunSnapshot(results: ["a": finished(verdict: "failed")])
        snap.finishedAt["a"] = t(10)
        let first = CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap)
        #expect(first == CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap))
        snap.finishedAt["a"] = t(20)
        #expect(first.key != CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap).key)
    }

    /// 시각이 같은 결과가 둘이면 먼저 등록한 환경을 유지한다(알림마다 오가지 않게).
    @Test func tieKeepsFirstRegistered() {
        var snap = RunSnapshot(results: ["a": finished(verdict: "failed"), "b": finished(verdict: "passed")])
        snap.finishedAt = ["a": t(10), "b": t(10)]
        #expect(CharacterPresentation.state(registry: twoEnvRegistry(), snapshot: snap).envID == "a")
    }
}

// MARK: 창 위치

@Suite struct CharacterPlacementTests {
    let size = CGSize(width: 120, height: 134)

    @Test func defaultIsBottomRightOfVisibleFrame() {
        let frame = CGRect(x: 0, y: 80, width: 1440, height: 795) // 아래 80pt는 Dock
        let origin = CharacterPlacement.defaultOrigin(visibleFrame: frame, size: size)
        #expect(origin == CGPoint(x: 1440 - 120 - 20, y: 100))
    }

    @Test func clampKeepsWindowInsideScreen() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(CharacterPlacement.clamp(origin: CGPoint(x: 950, y: -30), size: size, visibleFrames: [frame])
                == CGPoint(x: 880, y: 0))
        #expect(CharacterPlacement.clamp(origin: CGPoint(x: 300, y: 300), size: size, visibleFrames: [frame])
                == CGPoint(x: 300, y: 300))
    }

    /// 어느 화면과도 겹치지 않으면(모니터를 뺐을 때) nil. 호출하는 쪽이 기본 위치를 쓴다.
    @Test func offscreenIsNil() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(CharacterPlacement.clamp(origin: CGPoint(x: 2000, y: 100), size: size, visibleFrames: [frame]) == nil)
        #expect(CharacterPlacement.clamp(origin: .zero, size: size, visibleFrames: []) == nil)
    }

    /// 두 화면에 걸치면 더 많이 겹친 화면 안으로 넣는다.
    @Test func picksScreenWithLargestOverlap() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        #expect(CharacterPlacement.clamp(origin: CGPoint(x: 990, y: 100), size: size, visibleFrames: [left, right])
                == CGPoint(x: 1000, y: 100))
        #expect(CharacterPlacement.clamp(origin: CGPoint(x: 930, y: 100), size: size, visibleFrames: [left, right])
                == CGPoint(x: 880, y: 100))
    }

    @Test func smallMoveIsClick() {
        #expect(!CharacterPlacement.isDrag(dx: 2, dy: 2))
        #expect(CharacterPlacement.isDrag(dx: 4, dy: 0))
        #expect(CharacterPlacement.isDrag(dx: 0, dy: -5))
    }
}

// MARK: 페이지

@Suite struct CharacterPageTests {
    @Test func htmlHasTemplateForEveryPose() {
        let html = CharacterPage.html(svgs: [.idle: "<svg id=\"i\"></svg>", .failure: "<svg id=\"f\"></svg>"])
        for pose in CharacterPose.allCases {
            #expect(html.contains("<template id=\"pose-\(pose.rawValue)\">"))
        }
        #expect(html.contains("<template id=\"pose-idle\"><svg id=\"i\"></svg></template>"))
        // 빠진 포즈는 빈 템플릿(앱이 멈추지 않고 글씨만 보인다).
        #expect(html.contains("<template id=\"pose-running\"></template>"))
        #expect(html.contains("function setPose("))
        #expect(html.contains("background: transparent"))
    }

    @Test func scriptEscapesText() {
        let state = CharacterState(pose: .attention, label: "중단\"됨\\", envID: "a", key: "k'1", help: "")
        #expect(CharacterPage.script(for: state) == "setPose(\"attention\",\"중단\\\"됨\\\\\",\"k'1\")")
        #expect(CharacterPage.script(for: .idle) == "setPose(\"idle\",\"실행 전\",\"idle\")")
    }
}
