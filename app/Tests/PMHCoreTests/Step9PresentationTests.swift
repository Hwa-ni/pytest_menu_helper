// Step9PresentationTests.swift
// 9단계(여러 가상환경 동시 실행과 환경별 비교) 화면 값의 단위 테스트. 설계 docs/STEP9_DESIGN.md 5절 단위 4·5·6을 덮는다.
// 대상:
// - 4. 환경 비교 표(EnvComparison): 없음·미실행·미완료·수집 오류가 통과로 세지지 않음, 다른 결과 먼저·같은 것은 "모두 같음 N건",
//      열 머리(이름·Python 버전·출처·끝난 시각), 함께/따로 실행, 실행 조건(args) 다름 경고. 집계기 JSON의 args 디코드.
// - 5. 환경 B 결과가 환경 A 결과를 바꾸지 않음(회복 오판 없음). 실제 실행 경로는 RunTests.swift의
//      EnvironmentIsolationTests가, 여기서는 합친 상태(merged)·행·상세·비교·알림이 환경 키를 섞지 않는지 본다.
// - 6. 캐릭터 묶음 문구·포즈(CharacterPresentation)와 알림 묶음 요약 1건·낱개 알림 생략(NotificationPresentation).
// - 3.1 프로젝트 줄 [모두 실행]/[모두 중지] 값(ResultPresentation.projectRunAction, runAllTargets).
// 화면(SwiftUI)은 자동으로 확인하지 못하므로, 화면이 그대로 그리는 값을 여기서 고정한다.

import Foundation
import Testing
@testable import PMHCore

// MARK: 도움 함수

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// 테스트 결과 하나. 상태만 있으면 비교 표에는 충분하다.
private func test(_ nodeid: String, _ status: String, occurrence: Int = 1) -> TestResult {
    TestResult(nodeid: nodeid, occurrence: occurrence, status: status)
}

/// 집계 결과 하나를 결과 값으로 만든다. verdict는 건수와 상관없이 넘긴 값을 그대로 쓴다(Swift는 판정하지 않는다).
private func finished(verdict: String?, state: String = "completed", tests: [TestResult] = [], notRun: [String] = [],
                      errors: [String] = [], counts: [String: Int] = [:], args: [String]? = []) -> RunOutcome {
    .finished(RunSummary(state: state, verdict: verdict, exitCode: nil, counts: counts, tests: tests, notRun: notRun,
                         collectionErrors: errors.map { CollectionErrorRecord(nodeid: $0, failure: FailureInfo(message: "ImportError")) },
                         args: args))
}

private func readyCheck(_ version: [Int]) -> EnvCheck {
    EnvCheck(status: .ready, report: CheckReport(pythonVersion: version, pytestVersion: "9.2.0", fastapiVersion: nil,
                                                  pluginInstalled: true, pluginVersion: "0.3.0"), issues: [])
}

private func pluginMissingCheck() -> EnvCheck {
    EnvCheck(status: .actionNeeded, report: nil,
             issues: [PMHCore.Issue(code: .pluginMissing, severity: .actionNeeded, message: "플러그인이 없습니다", fixCommand: "uv pip ...")])
}

// 환경 세 개(a: 3.9, b: 3.12, c: 3.13)를 가진 프로젝트 하나. 설계 예시(fastapi_demo)와 같은 이름을 쓴다.
private let envA = PMHEnvironment(id: "a", name: "pmh-3.9", pythonPath: "/v/pmh-3.9/bin/python")
private let envB = PMHEnvironment(id: "b", name: "pmh-3.12", pythonPath: "/v/pmh-3.12/bin/python")
private let envC = PMHEnvironment(id: "c", name: "pmh-3.13", pythonPath: "/v/pmh-3.13/bin/python")
private let projectID = UUID()
private let project = Project(id: projectID, path: "/w/fastapi_demo", environments: [envA, envB, envC])
private let registry = Registry(projects: [project])
private let checks: [String: EnvCheck] = ["a": readyCheck([3, 9, 21]), "b": readyCheck([3, 12, 9]), "c": readyCheck([3, 13, 18])]

/// 결과를 환경 id 키로 넣은 상태. 끝난 시각은 envID마다 주거나, 기본은 100초.
private func snapshot(_ outcomes: [String: RunOutcome], finished: [String: TimeInterval] = [:],
                      batch: String? = nil) -> RunSnapshot {
    var s = RunSnapshot()
    for (env, outcome) in outcomes {
        s.results[env] = outcome
        s.runIDs[env] = "run-\(env)"
        s.finishedAt[env] = t(finished[env] ?? 100)
        if let batch = batch { s.batchIDs[env] = batch }
    }
    return s
}

private let utc = TimeZone(identifier: "UTC")!

// MARK: 4. 환경 비교 표

@Suite struct EnvComparisonTests {
    /// 없음·미실행·미완료·수집 오류는 통과로 세지 않는다. 한쪽 통과, 다른 쪽이 그런 값이면 "결과가 다름"이다.
    @Test func absentNotRunIncompleteAndCollectionErrorAreNotPasses() throws {
        let a = finished(verdict: "passed", tests: [
            test("t.py::same", "passed"), test("t.py::later", "passed"), test("t.py::cut", "passed"),
            test("pkg/test_c.py::x", "passed"), test("t.py::only_a", "passed"),
        ])
        let b = finished(verdict: "attention", tests: [test("t.py::same", "passed"), test("t.py::cut", "incomplete")],
                         notRun: ["t.py::later"], errors: ["pkg/test_c.py"])
        let model = try #require(EnvComparison.build(project: project, checks: checks,
                                                     snapshot: snapshot(["a": a, "b": b]), selectedEnvID: "a"))
        #expect(model.columns.map(\.id) == ["a", "b"])
        let byID = Dictionary(uniqueKeysWithValues: (model.differingRows + model.sameRows).map { ($0.id, $0) })
        #expect(byID["t.py::later#1"]?.cells == [.passed, .notRun])
        #expect(byID["t.py::cut#1"]?.cells == [.passed, .incomplete])
        #expect(byID["pkg/test_c.py::x#1"]?.cells == [.passed, .collectionError])
        #expect(byID["t.py::only_a#1"]?.cells == [.passed, .absent])
        // 모두 "다름"으로 분류되고, 같은 것은 통과끼리 하나뿐이다.
        #expect(model.differingRows.map(\.id) == ["t.py::later#1", "t.py::cut#1", "pkg/test_c.py::x#1", "t.py::only_a#1"])
        #expect(model.sameRows.map(\.id) == ["t.py::same#1"])
        #expect(model.sameSummary == "모두 같음 1건")
        // 칸 글자와 색: 없음·미실행은 중립, 수집 오류는 실패 색, 미완료는 주의 색. 어느 것도 통과 색이 아니다.
        #expect(ComparisonCell.absent.label == "없음" && ComparisonCell.absent.tone == .idle)
        #expect(ComparisonCell.notRun.label == "미실행" && ComparisonCell.notRun.tone == .idle)
        #expect(ComparisonCell.collectionError.label == "수집 오류" && ComparisonCell.collectionError.tone == .failed)
        #expect(ComparisonCell.incomplete.tone == .attention)
        // 집계기가 새로 만든 모르는 status도 통과로 보지 않는다.
        #expect(ComparisonCell(status: "weird") == .other("weird") && ComparisonCell(status: "weird").tone != .passed)
    }

    /// 결과가 다른 테스트를 먼저 두고(처음 보인 순서 유지), 모두 같은 테스트는 접어 수만 보인다.
    /// 3.9만 실패하는 multi_env_demo 모양: 다른 1건, 같은 5건.
    @Test func differingRowsFirstAndSameRowsCollapsed() throws {
        let names = ["test_shared.py::a", "test_shared.py::b", "test_version.py::test_strict_zip",
                     "test_shared.py::c", "test_shared.py::d", "test_shared.py::e"]
        let a = finished(verdict: "failed", tests: names.map { test($0, $0.contains("strict") ? "failed" : "passed") })
        let c = finished(verdict: "passed", tests: names.map { test($0, "passed") })
        let model = try #require(EnvComparison.build(project: project, checks: checks,
                                                     snapshot: snapshot(["a": a, "c": c]), selectedEnvID: "a"))
        #expect(model.differingRows.map(\.title) == ["test_version.py::test_strict_zip"])
        #expect(model.differingRows.first?.cells == [.failed, .passed])
        #expect(model.sameRows.count == 5 && model.sameSummary == "모두 같음 5건")
        #expect(model.sameRows.map(\.title) == names.filter { !$0.contains("strict") })
        #expect(model.warning == nil && model.notes.isEmpty)
    }

    /// 반복 수집된 같은 nodeid는 반복 번호끼리 맞대고, 어느 환경의 테스트로도 이어지지 않는 수집 오류는 따로 행이 된다.
    @Test func occurrencesAndOrphanCollectionErrors() throws {
        let a = finished(verdict: "failed", tests: [test("t.py::r", "passed"), test("t.py::r", "failed", occurrence: 2)],
                         errors: ["broken.py"])
        let b = finished(verdict: "passed", tests: [test("t.py::r", "passed"), test("t.py::r", "passed", occurrence: 2)])
        let model = try #require(EnvComparison.build(project: project, checks: checks,
                                                     snapshot: snapshot(["a": a, "b": b]), selectedEnvID: nil))
        #expect(model.differingRows.map(\.id) == ["t.py::r#2", "collect:broken.py"])
        #expect(model.differingRows.map(\.title) == ["t.py::r (2번째)", "broken.py (수집)"])
        #expect(model.differingRows.last?.cells == [.collectionError, .absent])
        #expect(model.sameRows.map(\.id) == ["t.py::r#1"])
        // 폴더 수집 오류는 그 폴더 아래 테스트만 덮는다("tests"가 "tests_other"를 덮지 않는다).
        #expect(EnvComparison.covers(error: "tests", nodeid: "tests/test_a.py::x"))
        #expect(!EnvComparison.covers(error: "tests", nodeid: "tests_other/test_b.py::y"))
        #expect(EnvComparison.covers(error: "tests/test_a.py", nodeid: "tests/test_a.py::x"))
    }

    /// 실행 인수가 다르면 경고. 모르는 값(nil, 옛 결과)은 "인수 없음"([])과 같다고 보지 않고 따로 안내만 한다.
    @Test func argsDifferenceWarning() throws {
        func model(_ argsA: [String]?, _ argsB: [String]?) throws -> EnvComparisonModel {
            let a = finished(verdict: "passed", tests: [test("t.py::x", "passed")], args: argsA)
            let b = finished(verdict: "passed", tests: [test("t.py::x", "passed")], args: argsB)
            return try #require(EnvComparison.build(project: project, checks: checks,
                                                    snapshot: snapshot(["a": a, "b": b]), selectedEnvID: nil))
        }
        let differ = try model(["-k", "slow"], [])
        #expect(differ.warning == "실행 조건이 달라 일부 테스트가 빠졌을 수 있습니다")
        #expect(differ.warning == EnvComparison.argsDifferWarning)
        // 표는 그대로 둔다(경고만 맨 위에 붙는다).
        #expect(differ.sameRows.count == 1)
        #expect(try model([], []).warning == nil)
        #expect(try model(["tests"], ["tests"]).warning == nil)
        let unknown = try model(nil, [])
        #expect(unknown.warning == nil)
        #expect(unknown.notes == ["실행 조건을 알 수 없는 결과가 있어 같은 조건인지 확인하지 못했습니다: pmh-3.9"])
    }

    /// 열 머리: 이름, Python 버전(검사 결과), 출처(앱·터미널), 끝난 시각. 같은 묶음이면 "함께 실행".
    @Test func columnHeadersAndTogetherRelation() throws {
        let out = finished(verdict: "passed", tests: [test("t.py::x", "passed")])
        var s = snapshot(["a": out, "c": out], finished: ["a": 3_600 * 14 + 3 * 60 + 12, "c": 3_600 * 14 + 4 * 60], batch: "B1")
        s.sources["c"] = .terminal
        var noCheck = checks
        noCheck["c"] = nil
        let model = try #require(EnvComparison.build(project: project, checks: noCheck, snapshot: s, selectedEnvID: "c",
                                                     now: t(3_600 * 15), timeZone: utc))
        #expect(model.columns == [
            ComparisonColumn(id: "a", name: "pmh-3.9", pythonText: "Python 3.9.21", sourceText: "앱",
                             finishedText: "14:03:12 끝남", isSelected: false),
            ComparisonColumn(id: "c", name: "pmh-3.13", pythonText: "검사 중", sourceText: "터미널",
                             finishedText: "14:04:00 끝남", isSelected: true),
        ])
        #expect(model.relationText == "함께 실행")
        // 오늘이 아닌 결과는 날짜를 붙여, 어제 결과를 같은 시점 결과로 오해하지 않게 한다.
        #expect(EnvComparison.finishedText(t(0), now: t(86_400 * 3), timeZone: utc) == "1월 1일 00:00 끝남")
    }

    /// 묶음이 다르거나 없으면 "따로 실행 · 시작 차이 N분". 시작 시각 = 끝난 시각 - 소요 시간.
    @Test func separateRelationShowsStartGap() throws {
        let out = finished(verdict: "passed", tests: [test("t.py::x", "passed")])
        var s = snapshot(["a": out, "b": out], finished: ["a": 1_000, "b": 1_000 + 12 * 60 + 30])
        s.elapsed = ["a": 10, "b": 40]
        s.batchIDs = ["a": "B1"] // b는 낱개 실행 결과
        let model = try #require(EnvComparison.build(project: project, checks: checks, snapshot: s, selectedEnvID: nil))
        // 시작: a = 1000 - 10 = 990, b = 1750 - 40 = 1710. 차이 720초 = 12분.
        #expect(model.relationText == "따로 실행 · 시작 차이 12분")
        #expect(EnvComparison.gapText(30) == "1분 미만")
        #expect(EnvComparison.gapText(3_600 + 5 * 60) == "1시간 5분")
        s.batchIDs = ["a": "B1", "b": "B2"]
        #expect(EnvComparison.relation(envIDs: ["a", "b"], snapshot: s) == "따로 실행 · 시작 차이 12분")
    }

    /// 결과가 있는 환경이 2개 미만이면 절을 숨긴다. 테스트별 결과가 없는 결과(실행 오류 등)는 비교에서 빼고 이유를 적는다.
    @Test func visibilityAndExcludedOutcomes() throws {
        let out = finished(verdict: "passed", tests: [test("t.py::x", "passed")])
        #expect(EnvComparison.build(project: project, checks: checks, snapshot: snapshot(["a": out]), selectedEnvID: "a") == nil)
        let twoButOne = try #require(EnvComparison.build(
            project: project, checks: checks,
            snapshot: snapshot(["a": out, "b": .launchFailed(message: "x")]), selectedEnvID: "a"))
        #expect(twoButOne.columns.map(\.id) == ["a"])
        #expect(twoButOne.notes == ["테스트별 결과가 없어 비교에서 뺐습니다: pmh-3.12(실행 오류)", EnvComparison.needTwoNote])
        #expect(twoButOne.differingRows.isEmpty && twoButOne.relationText == nil)
        let three = try #require(EnvComparison.build(
            project: project, checks: checks,
            snapshot: snapshot(["a": out, "b": .incomplete(termination: .signal(9), stopped: true, done: 1, total: 2), "c": out]),
            selectedEnvID: "a"))
        #expect(three.columns.map(\.id) == ["a", "c"])
        #expect(three.notes == ["테스트별 결과가 없어 비교에서 뺐습니다: pmh-3.12(미완료 · 중지함)"])
    }

    /// 팝오버 전체 값에 비교 절이 들어간다. 선택 환경이 열 강조로 표시된다.
    @Test func popoverStateCarriesComparison() {
        let out = finished(verdict: "passed", tests: [test("t.py::x", "passed")])
        let state = ResultPresentation.build(registry: registry, checks: checks, snapshot: snapshot(["a": out, "c": out]),
                                             preferredProjectID: nil, preferredEnvID: "c")
        #expect(state.comparison?.columns.map(\.isSelected) == [false, true])
        let single = ResultPresentation.build(registry: registry, checks: checks, snapshot: snapshot(["a": out]),
                                              preferredProjectID: nil, preferredEnvID: nil)
        #expect(single.comparison == nil)
    }
}

// MARK: 4. 집계기 JSON의 args

@Suite struct SummaryArgsDecodeTests {
    private func decode(_ args: String) throws -> RunSummary {
        let json = "{\"state\":\"completed\",\"verdict\":\"passed\",\"counts\":{\"passed\":1}\(args)}"
        return try JSONDecoder().decode(RunSummary.self, from: Data(json.utf8))
    }

    /// null과 키 없음은 "알 수 없음"(nil), []는 "인수 없음". 모양이 틀린 값은 결과 전체를 깨지 않고 nil이다.
    @Test func argsNullEmptyMissingAndMalformed() throws {
        #expect(try decode(",\"args\":[\"-k\",\"slow\"]").args == ["-k", "slow"])
        #expect(try decode(",\"args\":[]").args == [])
        #expect(try decode(",\"args\":null").args == nil)
        #expect(try decode("").args == nil)
        let bad = try decode(",\"args\":[1,2]")
        #expect(bad.args == nil && bad.verdict == "passed" && bad.counts["passed"] == 1)
        #expect(try decode(",\"args\":\"-k\"").args == nil)
    }
}

// MARK: 5. 환경 B 결과가 환경 A 결과를 바꾸지 않음(회복 오판 없음)

@Suite struct NoCrossEnvironmentRecoveryTests {
    /// 환경 A가 실패한 뒤 환경 B가 통과해도(앱 실행이든 터미널 실행이든) A의 결과·행 문구·상세·실행 ID는 그대로다.
    /// 비교 표는 "A 실패, B 통과"를 환경 차이(결과가 다름)로 보여 줄 뿐 A의 회복으로 보이지 않는다.
    @Test func laterPassInOtherEnvironmentDoesNotRecoverThisOne() throws {
        let failA = finished(verdict: "failed", tests: [test("test_version.py::test_strict_zip", "failed")],
                             counts: ["failed": 1])
        let passB = finished(verdict: "passed", tests: [test("test_version.py::test_strict_zip", "passed")],
                             counts: ["passed": 1])
        let before = snapshot(["a": failA], finished: ["a": 100])
        let rowBefore = ResultPresentation.row(env: envA, check: checks["a"], snapshot: before, selected: true)

        // B가 앱 실행으로 나중에 통과.
        var appLater = before
        appLater.results["b"] = passB; appLater.runIDs["b"] = "run-b"; appLater.finishedAt["b"] = t(200)
        // B가 터미널 실행으로 나중에 통과(합친 상태).
        let terminalLater = before.merged(external: ExternalSnapshot(results: [
            "b": ExternalResult(runID: "ext-b", envID: "b", outcome: passB, elapsed: 1, finishedAt: t(300)),
        ]))
        for later in [appLater, terminalLater] {
            #expect(later.results["a"] == failA)
            #expect(later.runIDs["a"] == "run-a" && later.finishedAt["a"] == t(100) && later.sources["a"] == nil)
            let row = ResultPresentation.row(env: envA, check: checks["a"], snapshot: later, selected: true)
            #expect(row == rowBefore && row.statusText == "실패 1")
            let state = ResultPresentation.build(registry: registry, checks: checks, snapshot: later,
                                                 preferredProjectID: nil, preferredEnvID: "a")
            #expect(state.detail?.headline == "실패")
            let cmp = try #require(state.comparison)
            #expect(cmp.differingRows.map(\.cells) == [[.failed, .passed]])
            // 알림: A는 이미 처리한 실행이라 다시 나가지 않고, B 알림은 B 환경 이름으로만 나간다.
            let d = NotificationPresentation.decisions(registry: registry, snapshot: later, handled: ["run-a"], enabled: true)
            #expect(d.count == 1)
            guard case .send(let n) = d.first else { Issue.record("B 알림이 있어야 함"); continue }
            #expect(n.envID == "b" && n.title.contains("pmh-3.12") && !n.title.contains("pmh-3.9"))
        }
    }
}

// MARK: 6. 캐릭터 묶음

@Suite struct CharacterBatchTests {
    /// a·b·c 세 환경 묶음 B1. a는 실행 중, b는 차례 기다림, c는 실행 중.
    private func runningBatch() -> RunSnapshot {
        var s = RunSnapshot()
        s.actives["a"] = ActiveRun(runID: "ra", envID: "a", projectPath: project.path, phase: .running(done: 1, total: 6),
                                   stopping: false, startedAt: t(10), batchID: "B1")
        s.actives["b"] = ActiveRun(runID: "rb", envID: "b", projectPath: project.path, phase: .queued,
                                   stopping: false, startedAt: t(10), batchID: "B1")
        s.actives["c"] = ActiveRun(runID: "rc", envID: "c", projectPath: project.path, phase: .running(done: 2, total: 6),
                                   stopping: false, startedAt: t(10), batchID: "B1")
        s.batches["B1"] = BatchState(envIDs: ["a", "b", "c"], runIDs: ["a": "ra", "b": "rb", "c": "rc"],
                                     projectPath: project.path, startedAt: t(10))
        return s
    }

    /// 실행 중: 달리기 + "3개 환경 실행 중", 끝난 환경이 생기면 "3개 환경 중 1개 끝남". key는 그대로(애니메이션 유지).
    /// 도움말에는 환경마다 한 줄씩 붙는다.
    @Test func runningBatchLabelAndHelp() {
        var s = runningBatch()
        var state = CharacterPresentation.state(registry: registry, snapshot: s)
        #expect(state.pose == .running && state.label == "3개 환경 실행 중")
        #expect(state.key == "batch:B1" && state.envID == "a")
        #expect(state.help == "fastapi_demo · 3개 환경 실행 중\npmh-3.9 · 실행 중 1/6\npmh-3.12 · 차례 기다림\npmh-3.13 · 실행 중 2/6")
        // a가 실패로 끝남.
        s.actives["a"] = nil
        s.results["a"] = finished(verdict: "failed", counts: ["failed": 1]); s.runIDs["a"] = "ra"; s.batchIDs["a"] = "B1"
        s.finishedAt["a"] = t(20)
        s.batches["B1"]?.completedEnvIDs = ["a"]
        state = CharacterPresentation.state(registry: registry, snapshot: s)
        #expect(state.pose == .running && state.label == "3개 환경 중 1개 끝남" && state.key == "batch:B1")
        #expect(state.envID == "c") // 지금 실제로 도는 첫 환경
        #expect(state.help.contains("pmh-3.9 · 실패 1"))
    }

    /// 다 끝난 묶음: 하나라도 실패면 넘어짐 "1/3 환경 실패", 모두 통과면 점프 "3개 환경 통과", 그 밖은 갸웃.
    @Test func finishedBatchPoseAndLabel() {
        func done(_ outcomes: [String: RunOutcome], cancelled: Set<String> = []) -> CharacterState {
            var s = snapshot(outcomes, finished: ["a": 30, "b": 31, "c": 32], batch: "B1")
            for env in cancelled { s.results[env] = nil; s.batchIDs[env] = nil; s.runIDs[env] = nil }
            s.batches["B1"] = BatchState(envIDs: ["a", "b", "c"], runIDs: ["a": "run-a", "b": "run-b", "c": "run-c"],
                                         projectPath: project.path, startedAt: t(10),
                                         completedEnvIDs: Set(outcomes.keys).subtracting(cancelled),
                                         cancelledEnvIDs: cancelled, finishedAt: t(32))
            return CharacterPresentation.state(registry: registry, snapshot: s)
        }
        let pass = finished(verdict: "passed", counts: ["passed": 6])
        let fail = finished(verdict: "failed", counts: ["passed": 5, "failed": 1])
        let skip = finished(verdict: "attention", counts: ["skipped": 1])

        let failed = done(["a": fail, "b": pass, "c": pass])
        #expect(failed.pose == .failure && failed.label == "1/3 환경 실패" && failed.envID == "a")
        #expect(failed.help == "fastapi_demo · 1/3 환경 실패\npmh-3.9 · 실패 1\npmh-3.12 · 통과\npmh-3.13 · 통과")
        #expect(failed.key == "batch-result:B1:32.0")

        let passed = done(["a": pass, "b": pass, "c": pass])
        #expect(passed.pose == .success && passed.label == "3개 환경 통과")

        let attention = done(["a": pass, "b": skip, "c": pass])
        #expect(attention.pose == .attention && attention.label == "3개 환경 중 2개 통과" && attention.envID == "b")

        // 차례 기다림을 취소한 환경이 있으면 나머지가 통과여도 점프하지 않는다(실행하지 않은 환경이 있다).
        let cancelled = done(["a": pass, "b": pass, "c": pass], cancelled: ["c"])
        #expect(cancelled.pose == .attention && cancelled.label == "3개 환경 중 2개 통과")
        #expect(cancelled.help.hasSuffix("pmh-3.13 · 차례 기다림 취소"))
    }

    /// 리뷰 결함 3: 멤버가 모두 차례 기다림인 묶음(동시 실행 수가 다른 실행으로 다 찬 뒤 [모두 실행])은 달리기 후보가 아니다.
    /// 나중에 시작한 묶음이라도 실제로 도는 낱개 실행을 가리지 않는다. 멤버 하나가 실제로 시작하면 그때 묶음을 따른다.
    @Test func allQueuedBatchDoesNotHideRunningSingleRun() {
        var s = RunSnapshot()
        s.actives["c"] = ActiveRun(runID: "rc", envID: "c", projectPath: project.path, phase: .running(done: 3, total: 6),
                                   stopping: false, startedAt: t(5))
        for env in ["a", "b"] {
            s.actives[env] = ActiveRun(runID: "r\(env)", envID: env, projectPath: project.path, phase: .queued,
                                       stopping: false, startedAt: t(10), batchID: "B1")
        }
        s.batches["B1"] = BatchState(envIDs: ["a", "b"], runIDs: ["a": "ra", "b": "rb"], projectPath: project.path,
                                     startedAt: t(10))
        var state = CharacterPresentation.state(registry: registry, snapshot: s)
        #expect(state.pose == .running && state.key == "run:rc" && state.label == "실행 중 3/6" && state.envID == "c")
        // 모두 차례 기다림이고 도는 실행이 하나도 없으면 달리지 않는다(이전 결과가 없으니 대기 포즈).
        var onlyQueued = s
        onlyQueued.actives["c"] = nil
        #expect(CharacterPresentation.state(registry: registry, snapshot: onlyQueued).pose != .running)
        // a가 실제로 시작하면 나중에 시작한 묶음이 이긴다.
        s.actives["a"]?.phase = .waitingForEvents
        state = CharacterPresentation.state(registry: registry, snapshot: s)
        #expect(state.key == "batch:B1" && state.label == "2개 환경 실행 중" && state.envID == "a")
    }

    /// 낱개 실행 규칙은 그대로다. 묶음보다 나중 것이 있으면 그것을 따르고, 환경 1개짜리 묶음은 낱개와 같다.
    @Test func singleRunsKeepStep7Rules() {
        let pass = finished(verdict: "passed", counts: ["passed": 6])
        let fail = finished(verdict: "failed", counts: ["failed": 1])
        var s = snapshot(["a": fail, "b": pass, "c": pass], finished: ["a": 30, "b": 31, "c": 32], batch: "B1")
        s.batches["B1"] = BatchState(envIDs: ["a", "b", "c"], runIDs: ["a": "run-a", "b": "run-b", "c": "run-c"],
                                     projectPath: project.path, startedAt: t(10),
                                     completedEnvIDs: ["a", "b", "c"], finishedAt: t(32))
        // b를 낱개로 다시 돌리는 중이면 낱개 달리기(실행 id key, 환경 행 문구).
        s.actives["b"] = ActiveRun(runID: "rb2", envID: "b", projectPath: project.path, phase: .running(done: 0, total: 6),
                                   stopping: false, startedAt: t(40))
        var state = CharacterPresentation.state(registry: registry, snapshot: s)
        #expect(state.pose == .running && state.key == "run:rb2" && state.label == "실행 중 0/6" && state.help == "pmh-3.12 · 실행 중 0/6")
        // 끝나면 b의 낱개 결과가 가장 나중이라 그것을 따른다(묶음 ID는 지워진다).
        s.actives["b"] = nil
        s.results["b"] = fail; s.batchIDs["b"] = nil; s.runIDs["b"] = "rb2"; s.finishedAt["b"] = t(50)
        state = CharacterPresentation.state(registry: registry, snapshot: s)
        #expect(state.pose == .failure && state.envID == "b" && state.label == "실패 1" && state.help == "pmh-3.12 · 실패 1")

        // 환경 1개짜리 묶음은 낱개 규칙(환경 이름과 행 문구).
        var one = snapshot(["a": pass], finished: ["a": 30], batch: "B2")
        one.batches["B2"] = BatchState(envIDs: ["a"], runIDs: ["a": "run-a"], projectPath: project.path, startedAt: t(10),
                                       completedEnvIDs: ["a"], finishedAt: t(30))
        state = CharacterPresentation.state(registry: registry, snapshot: one)
        #expect(state.pose == .success && state.label == "통과" && state.help == "pmh-3.9 · 통과")
    }
}

// MARK: 6. 알림 묶음 요약

@Suite struct BatchNotificationTests {
    private let pass = finished(verdict: "passed", counts: ["passed": 6])
    private let fail = finished(verdict: "failed", counts: ["passed": 5, "failed": 1])

    private func batch(finished: Bool, completed: Set<String> = ["a", "b", "c"], cancelled: Set<String> = []) -> BatchState {
        BatchState(envIDs: ["a", "b", "c"], runIDs: ["a": "run-a", "b": "run-b", "c": "run-c"], projectPath: project.path,
                   startedAt: t(10), completedEnvIDs: completed, cancelledEnvIDs: cancelled, finishedAt: finished ? t(40) : nil)
    }

    /// 묶음이 끝나기 전에는 먼저 끝난 환경에도 낱개 알림을 보내지 않는다. 다 끝나면 요약 1건.
    @Test func oneSummaryAfterAllFinishAndNoSingleNotices() {
        var s = snapshot(["a": fail], batch: "B1")
        s.batches["B1"] = batch(finished: false, completed: ["a"])
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true).isEmpty)

        s = snapshot(["a": fail, "b": pass, "c": pass], batch: "B1")
        s.batches["B1"] = batch(finished: true)
        let d = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true)
        #expect(d.count == 1)
        guard case .send(let n) = d.first else { Issue.record("요약을 보내야 함"); return }
        #expect(n.identifier == "B1")
        #expect(n.title == "3개 환경 중 1개 실패 · fastapi_demo")
        #expect(n.body == "pmh-3.9 실패 1 · pmh-3.12 통과 · pmh-3.13 통과")
        #expect(n.envID == "a" && n.showsComparison) // 누르면 실패한 첫 환경과 환경 비교 절
        // 묶음 ID와 실행 ID를 모두 처리함으로 넣는다. 그러면 같은 상태에서 다시 불러도 아무것도 나가지 않는다.
        #expect(Set(d[0].handledIDs) == ["B1", "run-a", "run-b", "run-c"])
        let handled = Set(d.flatMap(\.handledIDs))
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: handled, enabled: true).isEmpty)
        // 묶음이 정리된 뒤(모든 결과가 바뀌기 전 상태 그대로, batches만 비움)에도 실행 ID가 처리됨이라 낱개 알림이 나가지 않는다.
        var pruned = s
        pruned.batches = [:]
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: pruned, handled: handled, enabled: true).isEmpty)

        // 모두 통과면 "3개 환경 통과".
        var allPass = snapshot(["a": pass, "b": pass, "c": pass], batch: "B1")
        allPass.batches["B1"] = batch(finished: true)
        guard case .send(let p)? = NotificationPresentation.decisions(registry: registry, snapshot: allPass, handled: [],
                                                                       enabled: true).first
        else { Issue.record("요약을 보내야 함"); return }
        #expect(p.title == "3개 환경 통과 · fastapi_demo" && p.envID == "a")
    }

    /// 일부를 ■로 멈췄으면(실행 중 중지, 차례 기다림 취소) 그 환경은 "중단됨"으로 요약에 넣는다. 모두 멈췄으면 보내지 않는다.
    @Test func stoppedMembersAreSummarizedAsInterruptedAndAllStoppedSkips() {
        var s = snapshot(["a": fail, "b": .incomplete(termination: .signal(9), stopped: true, done: 1, total: 6)], batch: "B1")
        s.batches["B1"] = batch(finished: true, completed: ["a", "b"], cancelled: ["c"])
        guard case .send(let n)? = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [],
                                                                       enabled: true).first
        else { Issue.record("요약을 보내야 함"); return }
        #expect(n.title == "3개 환경 중 1개 실패 · fastapi_demo")
        #expect(n.body == "pmh-3.9 실패 1 · pmh-3.12 중단됨 · pmh-3.13 중단됨")

        // 집계 interrupted(SIGINT로 pytest가 스스로 멈춤)도 중단됨이다. 모두 멈췄으면 "중단"으로 처리만 한다.
        var all = snapshot(["a": finished(verdict: nil, state: "interrupted"),
                            "b": .incomplete(termination: .signal(9), stopped: true, done: 0, total: nil)], batch: "B1")
        all.batches["B1"] = batch(finished: true, completed: ["a", "b"], cancelled: ["c"])
        let d = NotificationPresentation.decisions(registry: registry, snapshot: all, handled: [], enabled: true)
        #expect(d == [.skip(runID: "B1", envID: "a", reason: "중단", covered: ["run-a", "run-b", "run-c"])])

        // 토글이 꺼져 있으면 보내지 않고 처리만 한다(낱개 규칙과 같다).
        var off = snapshot(["a": fail, "b": pass, "c": pass], batch: "B1")
        off.batches["B1"] = batch(finished: true)
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: off, handled: [], enabled: false)
                == [.skip(runID: "B1", envID: "a", reason: "완료 알림 꺼짐", covered: ["run-a", "run-b", "run-c"])])
    }

    /// 리뷰 추가: 묶음이 아직 도는 중에 먼저 끝난 멤버 a를 낱개 ▶로 다시 돌린 경우(지금 구현의 실제 동작을 고정한다).
    /// - a의 낱개 실행 결과는 묶음 실행 ID가 아니라서 낱개 알림 1건이 바로 나간다(묶음이 끝나기를 기다리지 않는다).
    /// - 묶음이 끝나면 요약 1건이 나가고, 결과가 낱개 실행으로 바뀐 a는 요약에서 빠진다(나머지 2개 환경만 센다).
    /// - a의 첫 묶음 실행 ID도 요약의 처리 ID에 들어가, 나중에 따로 알림이 나가지 않는다.
    @Test func rerunFinishedMemberWhileBatchStillRunning() {
        // 묶음 진행 중: a는 묶음에서 실패로 끝났고 b·c는 아직 돈다.
        var s = snapshot(["a": fail], batch: "B1")
        s.batches["B1"] = batch(finished: false, completed: ["a"])
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true).isEmpty)
        // a를 낱개로 다시 돌려 통과(RunController.complete가 runIDs를 새 실행으로, batchIDs를 nil로 바꾼다).
        s.results["a"] = pass; s.runIDs["a"] = "run-a2"; s.batchIDs["a"] = nil; s.finishedAt["a"] = t(150)
        let first = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true)
        #expect(first.map(\.runID) == ["run-a2"])
        guard case .send(let single)? = first.first else { Issue.record("a 낱개 알림"); return }
        #expect(single.title == "통과 · fastapi_demo / pmh-3.9" && !single.showsComparison)
        var handled = Set(first.flatMap(\.handledIDs))
        // b·c가 끝나 묶음이 끝남.
        s.results["b"] = fail; s.runIDs["b"] = "run-b"; s.batchIDs["b"] = "B1"; s.finishedAt["b"] = t(160)
        s.results["c"] = pass; s.runIDs["c"] = "run-c"; s.batchIDs["c"] = "B1"; s.finishedAt["c"] = t(170)
        s.batches["B1"] = batch(finished: true)
        // 실제로는 마지막 멤버(c)가 끝난 시각이 묶음 끝난 시각이다(도움 함수의 기본값 40초를 바로잡는다).
        s.batches["B1"]?.finishedAt = t(170)
        let second = NotificationPresentation.decisions(registry: registry, snapshot: s, handled: handled, enabled: true)
        #expect(second.count == 1)
        guard case .send(let summary)? = second.first else { Issue.record("묶음 요약"); return }
        #expect(summary.identifier == "B1")
        #expect(summary.title == "2개 환경 중 1개 실패 · fastapi_demo")
        #expect(summary.body == "pmh-3.12 실패 1 · pmh-3.13 통과")
        #expect(summary.envID == "b")
        handled.formUnion(second.flatMap(\.handledIDs))
        #expect(handled.isSuperset(of: ["run-a", "run-a2", "run-b", "run-c", "B1"]))
        #expect(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: handled, enabled: true).isEmpty)
        // 캐릭터: 가장 나중에 끝난 것은 묶음(170초)이고, 요약에는 a가 "다른 실행 결과로 바뀜"으로 보인다.
        let character = CharacterPresentation.state(registry: registry, snapshot: s)
        #expect(character.pose == .failure && character.label == "1/2 환경 실패" && character.envID == "b")
        #expect(character.help.contains("pmh-3.9 · 다른 실행 결과로 바뀜"))
    }

    /// 낱개 ▶와 터미널 실행은 8단계 규칙 그대로 1건씩이다. 묶음 뒤 낱개로 다시 돌린 환경도 낱개 알림이 나간다.
    /// 환경 1개짜리 묶음도 낱개 알림이다.
    @Test func singleAndTerminalRunsKeepStep8Rules() {
        var s = snapshot(["a": fail, "b": pass, "c": pass], batch: "B1")
        s.batches["B1"] = batch(finished: true)
        let handled = Set(NotificationPresentation.decisions(registry: registry, snapshot: s, handled: [], enabled: true)
            .flatMap(\.handledIDs))
        // b를 낱개로 다시 실행해 끝남.
        s.results["b"] = fail; s.runIDs["b"] = "run-b2"; s.batchIDs["b"] = nil; s.finishedAt["b"] = t(60)
        // c는 터미널에서 다시 실행해 끝남(합친 상태가 묶음 ID를 지운다). 앱 결과(100초)보다 나중에 끝나야 이긴다.
        let merged = s.merged(external: ExternalSnapshot(results: [
            "c": ExternalResult(runID: "ext-c", envID: "c", outcome: pass, elapsed: 2, finishedAt: t(170)),
        ]))
        #expect(merged.batchIDs["c"] == nil)
        let d = NotificationPresentation.decisions(registry: registry, snapshot: merged, handled: handled, enabled: true)
        #expect(d.map(\.runID) == ["run-b2", "ext-c"])
        guard case .send(let terminal) = d.last else { Issue.record("터미널 알림"); return }
        #expect(terminal.title == "통과 · fastapi_demo / pmh-3.13 · 터미널" && !terminal.showsComparison)

        var one = snapshot(["a": pass], batch: "B2")
        one.batches["B2"] = BatchState(envIDs: ["a"], runIDs: ["a": "run-a"], projectPath: project.path, startedAt: t(10),
                                       completedEnvIDs: ["a"], finishedAt: t(30))
        guard case .send(let single)? = NotificationPresentation.decisions(registry: registry, snapshot: one, handled: [],
                                                                            enabled: true).first
        else { Issue.record("낱개 알림"); return }
        #expect(single.identifier == "run-a" && single.title == "통과 · fastapi_demo / pmh-3.9")
    }
}

// MARK: 3.1 프로젝트 줄 [모두 실행]/[모두 중지]

@Suite struct ProjectRunActionTests {
    /// [모두 실행]은 검사 통과·플러그인 있는 환경만 대상으로 하고, 건너뛸 환경은 도움말에 적는다.
    @Test func runAllTargetsOnlyEligibleEnvironments() {
        var c = checks
        c["b"] = pluginMissingCheck()
        c["c"] = nil // 검사 중
        #expect(ResultPresentation.runAllTargets(project: project, checks: c).map(\.id) == ["a"])
        let action = ResultPresentation.projectRunAction(project: project, checks: c, snapshot: RunSnapshot())
        guard case .runAll(let enabled, let help)? = action else { Issue.record("모두 실행이어야 함"); return }
        #expect(enabled)
        #expect(help == "실행할 수 있는 1개 환경을 함께 실행합니다. 동시 실행은 10개까지이고 넘치면 차례를 기다립니다. 건너뜀: pmh-3.12, pmh-3.13(행의 이유 참고)")
        // 실행할 환경이 없으면 꺼진다.
        let none = ResultPresentation.projectRunAction(project: project, checks: [:], snapshot: RunSnapshot())
        guard case .runAll(false, _)? = none else { Issue.record("꺼진 모두 실행이어야 함"); return }
        // 환경이 없는 프로젝트에는 버튼이 없다.
        #expect(ResultPresentation.projectRunAction(project: Project(path: "/w/empty"), checks: [:], snapshot: RunSnapshot()) == nil)
        // 동시 실행 수가 다 차도 [모두 실행]은 켜 둔다(넘치는 환경은 차례를 기다린다).
        var full = RunSnapshot()
        full.runLimit = 1
        full.actives["other"] = ActiveRun(runID: "o", envID: "other", projectPath: "/w/x", phase: .running(done: 0, total: 1), stopping: false)
        guard case .runAll(true, _)? = ResultPresentation.projectRunAction(project: project, checks: checks, snapshot: full)
        else { Issue.record("제한이 차도 켜져야 함"); return }
    }

    /// 이 프로젝트에 앱 실행(차례 기다림 포함)이 있으면 같은 자리가 [모두 중지]. 모두 중지하는 중이면 꺼진다.
    @Test func stopAllWhileAnyRunInProject() {
        var s = RunSnapshot()
        s.actives["b"] = ActiveRun(runID: "rb", envID: "b", projectPath: project.path, phase: .queued, stopping: false, batchID: "B1")
        guard case .stopAll(true, _)? = ResultPresentation.projectRunAction(project: project, checks: checks, snapshot: s)
        else { Issue.record("모두 중지여야 함"); return }
        s.actives["b"] = ActiveRun(runID: "rb", envID: "b", projectPath: project.path, phase: .running(done: 0, total: 1), stopping: true)
        guard case .stopAll(false, let help)? = ResultPresentation.projectRunAction(project: project, checks: checks, snapshot: s)
        else { Issue.record("꺼진 모두 중지여야 함"); return }
        #expect(help == "중지하는 중입니다.")
        // 다른 프로젝트의 실행만 있으면 이 프로젝트는 [모두 실행]이다.
        let other = RunSnapshot(actives: ["x": ActiveRun(runID: "x", envID: "x", projectPath: "/w/other", phase: .waitingForEvents, stopping: false)])
        guard case .runAll? = ResultPresentation.projectRunAction(project: project, checks: checks, snapshot: other)
        else { Issue.record("모두 실행이어야 함"); return }
        // 팝오버 전체 값에도 들어간다.
        let state = ResultPresentation.build(registry: registry, checks: checks, snapshot: s,
                                             preferredProjectID: nil, preferredEnvID: nil)
        guard case .stopAll? = state.projectRunAction else { Issue.record("팝오버 값"); return }
    }
}
