// PresentationTests.swift
// 5단계 팝오버 화면 로직(ResultPresentation)과 넓힌 RunSummary 디코드를 검사한다.
// 화면(SwiftUI)은 자동으로 확인하지 못하므로, 화면이 그대로 그리는 값(문구·링·건수·실패 목록·기본 선택)을 여기서 고정한다.

import Foundation
import Testing
@testable import PMHCore

/// 집계기 출력과 같은 모양의 JSON. 실제 출력에서 필드 이름과 null 위치를 그대로 옮겼다
/// (seq·timestamp 같은 디코드하지 않는 필드도 남겨 모르는 키를 무시하는지 함께 본다).
private let realisticJSON = """
{"state":"completed","verdict":"failed","run_id":"r1","project_root":"/w/proj",
 "env":{"id":"e","python_version":"3.13.18"},"exit_code":1,
 "counts":{"passed":1,"failed":1,"error":1,"skipped":1,"xfailed":0,"xpassed":0,"incomplete":1,"not_run":2},
 "tests":[
  {"nodeid":"t.py::ok","occurrence":1,"status":"passed","phases":{
    "setup":{"seq":3,"phase":"setup","outcome":"passed","wasxfail":null,"duration":0.001,"location":{"path":"/w/proj/t.py","line":10},"failure":null},
    "call":{"seq":4,"phase":"call","outcome":"passed","duration":0.5,"location":{"path":"/w/proj/t.py","line":10},"failure":null},
    "teardown":{"seq":5,"phase":"teardown","outcome":"passed","duration":0.002,"location":{"path":"/w/proj/t.py","line":10},"failure":null}}},
  {"nodeid":"t.py::bad","occurrence":1,"status":"failed","phases":{
    "setup":{"outcome":"passed","duration":0.0,"location":{"path":"/w/proj/t.py","line":14},"failure":null},
    "call":{"outcome":"failed","duration":0.1,"location":{"path":"/w/proj/t.py","line":14},
            "failure":{"path":"/w/proj/helpers.py","line":7,"message":"AssertionError: assert 200 == 500","detail":"Traceback...\\nE   assert 200 == 500"}},
    "teardown":{"outcome":"passed","duration":0.0,"location":{"path":"/w/proj/t.py","line":14},"failure":null}}},
  {"nodeid":"t.py::fx","occurrence":1,"status":"error","phases":{
    "setup":{"outcome":"failed","duration":0.0,"location":{"path":"/w/proj/t.py","line":20},
             "failure":{"path":null,"line":null,"message":"fixture 'db' not found","detail":"E  fixture 'db' not found"}},
    "teardown":{"outcome":"passed","duration":0.0,"location":{"path":"/w/proj/t.py","line":20},"failure":null}}},
  {"nodeid":"t.py::sk","occurrence":1,"status":"skipped","phases":{
    "setup":{"outcome":"skipped","duration":0.0,"location":null,"failure":null}}},
  {"nodeid":"t.py::cut","occurrence":2,"status":"incomplete","phases":{
    "setup":{"outcome":"passed","duration":0.0,"location":{"path":"/w/proj/t.py","line":30},"failure":null}}}
 ],
 "not_run":["t.py::later1","t.py::later2"],
 "collection_errors":[{"event":"collection_error","nodeid":"broken.py","failure":{"path":"/w/proj/broken.py","line":1,"message":"ImportError: x","detail":"Traceback ImportError"}}]}
"""

private func decodeSummary(_ json: String) throws -> RunSummary {
    try JSONDecoder().decode(RunSummary.self, from: Data(json.utf8))
}

private func readyCheck(_ version: [Int] = [3, 13, 18]) -> EnvCheck {
    EnvCheck(status: .ready, report: CheckReport(pythonVersion: version, pytestVersion: "9.2.0",
                                                  fastapiVersion: "0.1", pluginInstalled: true, pluginVersion: "0.3.0"),
             issues: [])
}

private func pluginMissingCheck() -> EnvCheck {
    EnvCheck(status: .actionNeeded, report: nil,
             issues: [PMHCore.Issue(code: .pluginMissing, severity: .actionNeeded, message: "플러그인이 없습니다", fixCommand: "uv pip ...")])
}

// MARK: 디코드

@Suite struct SummaryDecodingTests {
    @Test func decodesTestsFailuresNotRunAndCollectionErrors() throws {
        let s = try decodeSummary(realisticJSON)
        #expect(s.projectRoot == "/w/proj")
        #expect(s.tests.count == 5)
        #expect(s.notRun == ["t.py::later1", "t.py::later2"])
        #expect(s.collectionErrors.first?.nodeid == "broken.py")
        let bad = try #require(s.tests.first { $0.nodeid == "t.py::bad" })
        #expect(bad.failures.map(\.phase) == ["call"])
        #expect(bad.failures.first?.failure.detail?.contains("assert 200 == 500") == true)
        #expect(bad.location == SourceLocation(path: "/w/proj/t.py", line: 14))
        let ok = try #require(s.tests.first { $0.nodeid == "t.py::ok" })
        #expect(abs((ok.duration ?? 0) - 0.503) < 1e-9)
        // location이 null인 단계도 디코드된다.
        #expect(s.tests.first { $0.nodeid == "t.py::sk" }?.location == nil)
    }

    /// 4단계 형식(목록 필드 없음)도 그대로 읽어야 한다. 읽지 못하면 결과 전체가 집계 오류가 된다.
    @Test func olderSummaryWithoutListsStillDecodes() throws {
        let s = try decodeSummary("{\"state\":\"completed\",\"verdict\":\"passed\",\"exit_code\":0,\"counts\":{\"passed\":2}}")
        #expect(s.tests.isEmpty && s.notRun.isEmpty && s.collectionErrors.isEmpty && s.projectRoot == nil)
        #expect(s.counts["passed"] == 2)
    }

    @Test func testWithoutOccurrenceOrPhasesDefaults() throws {
        let s = try decodeSummary("{\"state\":\"incomplete\",\"counts\":{},\"tests\":[{\"nodeid\":\"a\",\"status\":\"incomplete\"}]}")
        #expect(s.tests.first?.occurrence == 1)
        #expect(s.tests.first?.missingPhases == ["setup", "teardown"])
    }

    @Test func missingCountsIsADecodeError() {
        #expect(throws: (any Error).self) { try decodeSummary("{\"state\":\"completed\"}") }
    }
}

// MARK: 건수·링·시간

@Suite struct CountAndRingTests {
    @Test func countItemsKeepOrderAndIncludeZeros() throws {
        let items = ResultPresentation.countItems(try decodeSummary(realisticJSON).counts)
        #expect(items.map(\.label) == ["통과", "실패", "오류", "skip", "xfail", "xpass", "미실행", "미완료"])
        #expect(items.map(\.value) == [1, 1, 1, 1, 0, 0, 2, 1])
        #expect(items.filter(\.isZero).map(\.key) == ["xfailed", "xpassed"])
    }

    @Test func collectedTotalAndFinishedCount() {
        let counts = ["passed": 1, "failed": 1, "error": 1, "skipped": 1, "incomplete": 1, "not_run": 2]
        #expect(ResultPresentation.collectedTotal(counts) == 7)
        #expect(ResultPresentation.finishedCount(counts) == 4) // 미실행 2, 미완료 1을 뺀다
        #expect(ResultPresentation.collectedTotal([:]) == 0)
    }

    @Test func passRingCapsAt99WhenNotAllPassed() {
        let r = ResultPresentation.passRing(passed: 199, total: 200)
        #expect(r.center == "99%" && r.caption == "통과 199/200")
        #expect(ResultPresentation.passRing(passed: 2, total: 2).center == "100%")
        #expect(ResultPresentation.passRing(passed: 1, total: 2).fraction == 0.5)
        let empty = ResultPresentation.passRing(passed: 0, total: 0)
        #expect(empty.fraction == nil && empty.center == "—")
    }

    @Test func progressRingHandlesUnknownAndZeroTotal() {
        #expect(ResultPresentation.progressRing(done: 3, total: 5).center == "3/5")
        #expect(ResultPresentation.progressRing(done: 3, total: 5).fraction == 0.6)
        #expect(ResultPresentation.progressRing(done: 2, total: nil).fraction == nil)
        #expect(ResultPresentation.progressRing(done: 0, total: 0).fraction == nil)
        // 범위를 벗어난 값은 잘라 둔다(링이 한 바퀴를 넘지 않게).
        #expect(ResultPresentation.progressRing(done: 7, total: 5).fraction == 1)
    }

    @Test func elapsedFormatting() {
        #expect(ResultPresentation.formatElapsed(0.08) == "0.1초")
        #expect(ResultPresentation.formatElapsed(-1) == "0.0초")
        #expect(ResultPresentation.formatElapsed(9.94) == "9.9초")
        #expect(ResultPresentation.formatElapsed(10.4) == "10초")
        #expect(ResultPresentation.formatElapsed(65) == "1분 5초")
        #expect(ResultPresentation.formatElapsed(3725) == "1시간 2분")
    }
}

// MARK: 행 문구

@Suite struct RowStatusTests {
    let env = PMHEnvironment(id: "e1", name: "pmh-3.13", pythonPath: "/p")

    @Test func failedCountIncludesErrors() throws {
        let s = try decodeSummary(realisticJSON)
        let status = ResultPresentation.outcomeStatus(.finished(s))
        #expect(status.text == "실패 2" && status.tone == .failed)
    }

    @Test func outcomeStatusCoversNonVerdictStates() {
        func s(_ state: String, _ verdict: String? = nil) -> RunOutcome {
            .finished(RunSummary(state: state, verdict: verdict, exitCode: nil, counts: [:]))
        }
        #expect(ResultPresentation.outcomeStatus(s("completed", "passed")).text == "통과")
        #expect(ResultPresentation.outcomeStatus(s("completed", "attention")).text == "확인 필요")
        #expect(ResultPresentation.outcomeStatus(s("interrupted")).text == "중단됨")
        #expect(ResultPresentation.outcomeStatus(s("collection_error")).tone == .failed)
        #expect(ResultPresentation.outcomeStatus(s("no_tests")).text == "테스트 없음")
        #expect(ResultPresentation.outcomeStatus(.incomplete(termination: .signal(9), stopped: true, done: 1, total: 5)).text == "미완료 · 중지함")
        #expect(ResultPresentation.outcomeStatus(.eventsMixed(foreign: 2)).text == "집계 오류")
        #expect(ResultPresentation.outcomeStatus(.launchFailed(message: "x")).tone == .failed)
    }

    @Test func runningRowShowsProgressAndStop() {
        let snap = RunSnapshot(active: ActiveRun(runID: "r", envID: "e1", projectPath: "/w",
                                                 phase: .running(done: 2, total: 5), stopping: false))
        let row = ResultPresentation.row(env: env, check: readyCheck(), snapshot: snap, selected: true)
        #expect(row.action == .stop(enabled: true))
        #expect(row.statusText == "실행 중 2/5" && row.tone == .running)
        #expect(row.progress == 0.4 && row.progressText == "2/5")
        #expect(row.versionText == "Python 3.13.18")
    }

    @Test func waitingAndStoppingRows() {
        var active = ActiveRun(runID: "r", envID: "e1", projectPath: "/w", phase: .waitingForEvents, stopping: false)
        var row = ResultPresentation.row(env: env, check: readyCheck(), snapshot: RunSnapshot(active: active), selected: false)
        #expect(row.indeterminate && row.progress == nil && row.statusText == "수집 대기")
        active.stopping = true
        row = ResultPresentation.row(env: env, check: readyCheck(), snapshot: RunSnapshot(active: active), selected: false)
        #expect(row.action == .stop(enabled: false) && row.statusText == "중지하는 중…")
    }

    /// 동시 실행은 앱 전체 1건이라, 다른 환경이 실행 중이면 이 환경의 ▶는 꺼진다.
    @Test func otherEnvironmentRunningDisablesRun() {
        let snap = RunSnapshot(active: ActiveRun(runID: "r", envID: "other", projectPath: "/w",
                                                 phase: .waitingForEvents, stopping: false))
        let row = ResultPresentation.row(env: env, check: readyCheck(), snapshot: snap, selected: false)
        #expect(row.action == .run(enabled: false))
        #expect(row.actionHelp?.contains("동시에 1건") == true)
        #expect(row.statusText == "실행 전")
    }

    @Test func checkingAndUnavailableRows() throws {
        var row = ResultPresentation.row(env: env, check: nil, snapshot: RunSnapshot(), selected: false)
        #expect(row.statusText == "환경 검사 중" && row.tone == .checking && row.action == .run(enabled: false))
        #expect(row.versionText == "검사 중")
        // 실행 불가 이유가 지난 결과보다 먼저 보인다. 지난 결과의 진행 바는 남긴다.
        let snap = RunSnapshot(results: ["e1": .finished(try decodeSummary(realisticJSON))])
        row = ResultPresentation.row(env: env, check: pluginMissingCheck(), snapshot: snap, selected: false)
        // 이유가 행 아래 조치 줄과 같은 문장이라 짧게 가리킨다. 전체 이유는 ▶ 도움말에 남는다.
        #expect(row.statusText == "실행 불가: 아래 문제를 먼저 해결하세요." && row.tone == .unavailable)
        #expect(row.actionHelp == "플러그인이 없습니다")
        #expect(row.issues.map(\.text) == ["조치 필요: 플러그인이 없습니다"])
        #expect(row.action == .run(enabled: false))
        #expect(row.progressText == "4/7")
    }

    @Test func idleRowWithResult() {
        let s = RunSummary(state: "completed", verdict: "passed", exitCode: 0, counts: ["passed": 5])
        let row = ResultPresentation.row(env: env, check: readyCheck(), snapshot: RunSnapshot(results: ["e1": .finished(s)]), selected: false)
        #expect(row.action == .run(enabled: true))
        #expect(row.statusText == "통과" && row.tone == .passed && row.progressText == "5/5")
    }
}

// MARK: 실패 목록

@Suite struct FailureListTests {
    @Test func listsCollectionErrorsThenFailedErrorIncompleteOnly() throws {
        let entries = ResultPresentation.failureEntries(try decodeSummary(realisticJSON))
        #expect(entries.map(\.statusLabel) == ["수집 오류", "실패", "오류", "미완료"])
        #expect(entries.map(\.id) == ["collect#0", "t.py::bad#1", "t.py::fx#1", "t.py::cut#2"])
        #expect(!entries.contains { $0.title.contains("t.py::sk") }) // skip은 넣지 않는다
    }

    /// 실패 위치(helpers.py:7)를 테스트 정의 위치(t.py:14)보다 우선하고, rootdir 기준 상대 경로로 줄인다.
    @Test func prefersFailureLocationAndShortensPath() throws {
        let entries = ResultPresentation.failureEntries(try decodeSummary(realisticJSON))
        let bad = try #require(entries.first { $0.id == "t.py::bad#1" })
        #expect(bad.locationText == "helpers.py:7")
        #expect(bad.summary == "AssertionError: assert 200 == 500")
        #expect(bad.sections.first?.title == "call 단계")
        #expect(bad.sections.first?.detail?.contains("Traceback") == true)
        // 실패 경로가 null이면 테스트 정의 위치를 쓴다.
        let fx = try #require(entries.first { $0.id == "t.py::fx#1" })
        #expect(fx.locationText == "t.py:20")
        #expect(fx.sections.first?.title == "setup 단계")
    }

    @Test func incompleteEntryExplainsMissingPhases() throws {
        let entries = ResultPresentation.failureEntries(try decodeSummary(realisticJSON))
        let cut = try #require(entries.first { $0.id == "t.py::cut#2" })
        #expect(cut.title == "t.py::cut (2번째)")
        #expect(cut.tone == .attention)
        #expect(cut.summary?.contains("teardown") == true)
    }

    @Test func locationTextEdgeCases() {
        #expect(ResultPresentation.locationText(path: "/a/proj/x.py", line: 3, root: "/a/proj") == "x.py:3")
        // "/a/pro"가 "/a/proj/..."의 앞부분이라도 폴더 경계가 아니면 줄이지 않는다.
        #expect(ResultPresentation.locationText(path: "/a/project/x.py", line: 3, root: "/a/proj") == "/a/project/x.py:3")
        #expect(ResultPresentation.locationText(path: "/a/x.py", line: nil, root: nil) == "/a/x.py")
        #expect(ResultPresentation.locationText(path: nil, line: 3, root: "/a") == nil)
    }
}

// MARK: 상세와 기본 선택

@Suite struct PopoverBuildTests {
    let e1 = PMHEnvironment(id: "e1", name: "pmh-3.12", pythonPath: "/p12")
    let e2 = PMHEnvironment(id: "e2", name: "pmh-3.13", pythonPath: "/p13")

    func registry() -> (Registry, Project, Project) {
        let a = Project(path: "/w/a", environments: [e1, e2])
        let b = Project(path: "/w/b", environments: [])
        return (Registry(projects: [a, b]), a, b)
    }

    @Test func defaultsToRunningEnvironmentThenFirst() {
        let (reg, a, _) = registry()
        let checks = ["e1": readyCheck(), "e2": readyCheck()]
        var state = ResultPresentation.build(registry: reg, checks: checks, snapshot: RunSnapshot(),
                                             preferredProjectID: nil, preferredEnvID: nil)
        #expect(state.selectedProjectID == a.id && state.selectedEnvID == "e1")
        #expect(state.rows.map(\.id) == ["e1", "e2"] && state.rows.map(\.isSelected) == [true, false])
        let running = RunSnapshot(active: ActiveRun(runID: "r", envID: "e2", projectPath: "/w/a",
                                                    phase: .running(done: 1, total: 3), stopping: false, startedAt: Date()))
        state = ResultPresentation.build(registry: reg, checks: checks, snapshot: running,
                                         preferredProjectID: nil, preferredEnvID: nil)
        #expect(state.selectedEnvID == "e2")
        #expect(state.detail?.tone == .running && state.detail?.liveStartedAt != nil)
        #expect(state.detail?.counts.isEmpty == true) // 실행 중에는 Swift가 건수를 세지 않는다
        #expect(state.detail?.progressRing.center == "1/3")
        // 사용자가 고른 환경은 실행 중인 환경보다 우선한다.
        state = ResultPresentation.build(registry: reg, checks: checks, snapshot: running,
                                         preferredProjectID: nil, preferredEnvID: "e1")
        #expect(state.selectedEnvID == "e1" && state.detail?.tone == .idle)
    }

    @Test func emptyMessagesForNoProjectOrNoEnvironment() {
        let (reg, _, b) = registry()
        #expect(ResultPresentation.build(registry: Registry(), checks: [:], snapshot: RunSnapshot(),
                                         preferredProjectID: nil, preferredEnvID: nil).emptyMessage?.contains("프로젝트 추가") == true)
        let state = ResultPresentation.build(registry: reg, checks: [:], snapshot: RunSnapshot(),
                                             preferredProjectID: b.id, preferredEnvID: "e1")
        #expect(state.selectedProjectID == b.id && state.rows.isEmpty && state.detail == nil)
        #expect(state.emptyMessage?.contains("환경 추가") == true)
        #expect(state.projects.count == 2)
    }

    /// 화면이 쓰는 링·건수가 집계기 counts와 같은 값에서 나오는지 확인한다(완료 기준: 터미널과 앱의 건수 일치).
    @Test func finishedDetailUsesAggregatorCounts() throws {
        let s = try decodeSummary(realisticJSON)
        let d = ResultPresentation.detail(envID: "e1", active: nil, outcome: .finished(s), elapsed: 1.25, blockedReason: nil)
        #expect(d.headline == "실패" && d.tone == .failed)
        #expect(d.progressRing.center == "4/7")
        #expect(d.passRing.caption == "통과 1/7")
        #expect(d.elapsedText == "1.2초" || d.elapsedText == "1.3초")
        #expect(d.counts.first { $0.key == "not_run" }?.value == 2)
        #expect(d.failures.count == 4)
        #expect(d.notes.contains { $0.contains("미실행 2건") })
    }

    @Test func detailForErrorsAndNoResult() {
        var d = ResultPresentation.detail(envID: "e", active: nil, outcome: nil, elapsed: nil, blockedReason: "플러그인이 없습니다")
        #expect(d.headline == "아직 실행하지 않았습니다" && d.elapsedText == "—")
        #expect(d.notes.last == "실행 불가: 플러그인이 없습니다")
        d = ResultPresentation.detail(envID: "e", active: nil,
                                      outcome: .collectionFailed(termination: .exit(3), logTail: "boom"), elapsed: 0.5, blockedReason: nil)
        #expect(d.tone == .failed && d.notes == ["로그 마지막 줄: boom"] && d.counts.isEmpty)
        d = ResultPresentation.detail(envID: "e", active: nil,
                                      outcome: .incomplete(termination: .signal(9), stopped: true, done: 2, total: 5),
                                      elapsed: 3, blockedReason: nil)
        #expect(d.progressRing.center == "2/5" && d.passRing.center == "—")
    }
}
