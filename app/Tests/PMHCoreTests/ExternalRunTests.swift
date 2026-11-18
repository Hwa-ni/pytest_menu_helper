// ExternalRunTests.swift
// 6단계(다른 터미널의 pytest 실행 감지) 단위 테스트.
// 대상: 공통 설정 파일 읽기(AppPaths.resolve), 이벤트 시각·session_start 해석, 프로젝트·환경 매칭,
//       프로세스 생존 확인, 앱 실행과 외부 실행 합치기(RunSnapshot.merged), 화면 값, 감시기(ExternalRunWatcher).
// 감시기는 임시 폴더에 이벤트 파일을 직접 쓰고, 생존 확인과 집계 호출을 가짜로 바꿔 시간에 기대지 않고 확인한다.

import Foundation
import Testing
@testable import PMHCore

// MARK: 도움 함수

/// 집계 호출 대신 정해 둔 JSON을 돌려주는 실행기. 호출 수를 세어 "1번만 집계"를 확인한다.
private final class StubAggregator: ProcessRunning {
    var json: String
    private(set) var calls: [[String]] = []
    init(json: String) { self.json = json }
    func run(executable: String, arguments: [String], workingDirectory: String, timeout: TimeInterval) -> ProcessOutput {
        calls.append([executable] + arguments)
        return ProcessOutput(exitCode: 0, stdout: Data(json.utf8), stderr: "", timedOut: false)
    }
}

/// 이벤트 한 줄(JSON)을 만든다. fields는 공통 필드 뒤에 붙는다.
private func eventLine(_ runID: String, _ event: String, _ fields: [String: Any] = [:], time: String = "2026-11-17T05:00:00+00:00") -> String {
    var object: [String: Any] = ["schema_version": 2, "event": event, "run_id": runID, "timestamp": time]
    for (k, v) in fields { object[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}

private func append(_ text: String, to url: URL) throws {
    if let handle = FileHandle(forWritingAtPath: url.path) {
        handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try handle.close()
    } else {
        try Data(text.utf8).write(to: url)
    }
}

private func newRunID() -> String { UUID().uuidString.lowercased() }

/// 감시기 테스트 환경: 임시 이벤트 폴더, 프로젝트 1개(환경 1개, prefix /venvs/a), 가짜 생존 상태와 집계기.
private final class WatchFixture {
    let dir = tempDir()
    let events: URL
    let projectID = UUID()
    let projectPath = "/work/proj"
    var alive: Set<Int32> = []
    var appRuns: Set<String> = []
    let aggregator = StubAggregator(json: "{\"state\":\"completed\",\"verdict\":\"failed\",\"exit_code\":1,\"run_id\":\"RID\",\"counts\":{\"passed\":1,\"failed\":1}}")
    var logs: [String] = []
    lazy var watcher: ExternalRunWatcher = ExternalRunWatcher(
        eventsDir: events, runner: aggregator, interval: 60,
        liveness: { [unowned self] pid, _ in self.alive.contains(pid) ? .alive : .dead },
        isAppRun: { [unowned self] in self.appRuns.contains($0) },
        notifyQueue: DispatchQueue(label: "test.external"), onChange: { _ in },
        onLog: { [unowned self] in self.logs.append($0) })

    init(prefix: String? = "/venvs/a") throws {
        events = dir.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        watcher.updateTargets([ProjectTarget(id: projectID, path: projectPath,
                                             environments: [EnvTarget(id: "envA", pythonPath: "/venvs/a/bin/python", prefix: prefix)])])
    }

    func file(_ runID: String) -> URL { events.appendingPathComponent("\(runID).jsonl") }

    /// 이 프로젝트·환경에서 실행한 session_start + session_collected를 쓴다.
    func start(_ runID: String, pid: Int32? = 4242, prefix: String = "/venvs/a", cwd: String = "/work/proj/tests",
               parent: String? = nil, nodeids: [String] = ["t::a", "t::b", "t::c"]) throws {
        var fields: [String: Any] = ["env": ["id": "hash", "prefix": prefix, "python_path": "/base/python3.13"],
                                     "invocation_dir": cwd, "project_root": "/work"]
        if let pid = pid { fields["pid"] = Int(pid) }
        fields["parent_run_id"] = parent ?? NSNull()
        try append(eventLine(runID, "session_start", fields), to: file(runID))
        try append(eventLine(runID, "session_collected", ["nodeids": nodeids]), to: file(runID))
    }

    func teardown(_ runID: String, _ node: String) throws {
        try append(eventLine(runID, "test_report", ["nodeid": node, "phase": "teardown", "outcome": "passed"]), to: file(runID))
    }

    func finish(_ runID: String) throws {
        try append(eventLine(runID, "session_finish", ["exit_code": 1, "collected": 3], time: "2026-11-17T05:00:12.500000+00:00"),
                   to: file(runID))
    }
}

// MARK: 공통 설정 파일

@Suite struct SharedConfigTests {
    private func base(with config: String?) throws -> URL {
        let base = tempDir().appendingPathComponent("data")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let config = config { try Data(config.utf8).write(to: base.appendingPathComponent("config.json")) }
        return base
    }

    @Test func missingFileUsesDefaultEventsFolderWithoutWarning() throws {
        let b = try base(with: nil)
        let r = AppPaths.resolve(base: b)
        #expect(r.paths.eventsDir == b.appendingPathComponent("events", isDirectory: true))
        #expect(r.warning == nil)
    }

    @Test func absoluteEventsDirIsUsedForEventFilesButNotLogs() throws {
        let b = try base(with: "{\"events_dir\": \"/tmp/pmh-shared\"}")
        let r = AppPaths.resolve(base: b)
        #expect(r.warning == nil)
        #expect(r.paths.eventsDir.path == "/tmp/pmh-shared")
        #expect(r.paths.eventsFile(runID: "x").path == "/tmp/pmh-shared/x.jsonl")
        // 로그와 등록 파일은 기준 폴더에 그대로 둔다(설정은 이벤트 폴더만 바꾼다).
        #expect(r.paths.logsDir == b.appendingPathComponent("logs", isDirectory: true))
    }

    @Test func tildeIsExpandedOnlyForCurrentHome() throws {
        let b = try base(with: "{\"events_dir\": \"~/ev\"}")
        #expect(AppPaths.resolve(base: b, home: "/Users/me").paths.eventsDir.path == "/Users/me/ev")
        // "~user"는 플러그인과 같게 풀지 않고 상대 경로로 본다.
        let other = try base(with: "{\"events_dir\": \"~bob/ev\"}")
        let r = AppPaths.resolve(base: other, home: "/Users/me")
        #expect(r.paths.eventsDirOverride == nil && r.warning != nil)
    }

    @Test func invalidValuesFallBackToDefaultWithWarning() throws {
        for config in ["{broken", "[]", "{\"events_dir\": 3}", "{\"events_dir\": \"  \"}", "{\"events_dir\": \"rel/ev\"}"] {
            let b = try base(with: config)
            let r = AppPaths.resolve(base: b)
            #expect(r.paths.eventsDirOverride == nil, "\(config)")
            #expect(r.warning?.contains("기본 이벤트 폴더") == true, "\(config)")
        }
    }

    @Test func fileWithoutEventsDirKeyIsNotAWarning() throws {
        let r = AppPaths.resolve(base: try base(with: "{\"other\": 1}"))
        #expect(r.paths.eventsDirOverride == nil && r.warning == nil)
    }
}

// MARK: 이벤트 해석

@Suite struct EventParsingTests {
    @Test func timestampWithMicrosecondsAndWithout() throws {
        let a = try #require(EventTime.parse("2026-11-17T05:00:00.250000+00:00"))
        let b = try #require(EventTime.parse("2026-11-17T05:00:00+00:00"))
        #expect(abs(a.timeIntervalSince(b) - 0.25) < 0.0001)
        #expect(EventTime.parse("2026-11-17T05:00:00Z") == b)
        #expect(EventTime.parse("2026-11-17T14:00:00+09:00") == b)
        #expect(EventTime.parse("not a time") == nil)
        #expect(EventTime.parse("2026-11-17T05:00:00.+00:00") == nil)
    }

    @Test func sessionStartFieldsAreRead() throws {
        let line = eventLine("r1", "session_start", ["pid": 77, "invocation_dir": "/p/sub", "project_root": "/p",
                                                     "parent_run_id": "r0",
                                                     "env": ["id": "abc", "prefix": "/v", "python_path": "/v/bin/python"]])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let info = try #require(SessionStartInfo.parse(object))
        #expect(info == SessionStartInfo(runID: "r1", timestamp: EventTime.parse("2026-11-17T05:00:00+00:00"), pid: 77,
                                         invocationDir: "/p/sub", projectRoot: "/p", envID: "abc", envPrefix: "/v",
                                         pythonPath: "/v/bin/python", parentRunID: "r0"))
        // 0.2.0 형식(새 필드 없음)도 읽고, null parent는 nil이다.
        let old = eventLine("r2", "session_start", ["parent_run_id": NSNull(), "env": ["id": "abc"]])
        let oldObject = try #require(try JSONSerialization.jsonObject(with: Data(old.utf8)) as? [String: Any])
        let oldInfo = try #require(SessionStartInfo.parse(oldObject))
        #expect(oldInfo.pid == nil && oldInfo.invocationDir == nil && oldInfo.parentRunID == nil && oldInfo.envPrefix == nil)
    }

    @Test func progressKeepsStartAndFinishTime() {
        var p = RunProgress(runID: "r")
        p.ingest(Data(eventLine("r", "session_start", ["pid": 5]).utf8))
        p.ingest(Data(eventLine("r", "session_finish", ["exit_code": 0], time: "2026-11-17T05:00:03+00:00").utf8))
        #expect(p.start?.pid == 5)
        #expect(p.finishedAt == EventTime.parse("2026-11-17T05:00:03+00:00"))
    }
}

// MARK: 매칭

@Suite struct MatchingTests {
    let pid = UUID(), nested = UUID()
    var projects: [ProjectTarget] {
        [ProjectTarget(id: pid, path: "/repo/proj", environments: [
            EnvTarget(id: "e1", pythonPath: "/v1/bin/python", prefix: "/v1"),
            EnvTarget(id: "e2", pythonPath: "/v2/bin/python", prefix: "/v2")]),
         ProjectTarget(id: nested, path: "/repo/proj/inner", environments: [
            EnvTarget(id: "e3", pythonPath: "/v1/bin/python", prefix: "/v1")])]
    }

    @Test func invocationDirSelectsDeepestProject() {
        let a = SessionStartInfo(runID: "r", invocationDir: "/repo/proj/tests", projectRoot: "/repo", envPrefix: "/v2")
        #expect(ExternalMatching.match(a, projects: projects) == .matched(projectID: pid, envID: "e2"))
        let b = SessionStartInfo(runID: "r", invocationDir: "/repo/proj/inner/x", projectRoot: "/repo", envPrefix: "/v1")
        #expect(ExternalMatching.match(b, projects: projects) == .matched(projectID: nested, envID: "e3"))
    }

    @Test func rootdirIsFallbackWhenInvocationDirIsOutside() {
        // 홈에서 `pytest /repo/proj` 처럼 실행한 경우.
        let a = SessionStartInfo(runID: "r", invocationDir: "/Users/me", projectRoot: "/repo/proj", envPrefix: "/v1")
        #expect(ExternalMatching.match(a, projects: projects) == .matched(projectID: pid, envID: "e1"))
        // 이름 앞부분만 같은 폴더(/repo/project)는 맞지 않는다.
        let b = SessionStartInfo(runID: "r", invocationDir: "/repo/project", projectRoot: "/repo/project", envPrefix: "/v1")
        #expect(ExternalMatching.match(b, projects: projects) == .noProject)
    }

    @Test func oldPluginMatchesByPrefixHashAndExplicitIDWins() {
        #expect(ExternalMatching.defaultEnvID(prefix: "/Users/me/.venvs/a") == "19162d683eb2") // Python hashlib와 같은 값
        let old = SessionStartInfo(runID: "r", projectRoot: "/repo/proj", envID: ExternalMatching.defaultEnvID(prefix: "/v2"))
        #expect(ExternalMatching.match(old, projects: projects) == .matched(projectID: pid, envID: "e2"))
        let explicit = SessionStartInfo(runID: "r", invocationDir: "/repo/proj", envID: "e1", envPrefix: "/other")
        #expect(ExternalMatching.match(explicit, projects: projects) == .matched(projectID: pid, envID: "e1"))
    }

    @Test func unregisteredAndWaitingForCheck() {
        let s = SessionStartInfo(runID: "r", invocationDir: "/repo/proj", envPrefix: "/v9")
        #expect(ExternalMatching.match(s, projects: projects) == .unregisteredEnvironment(projectID: pid))
        var pending = projects
        pending[0].environments[1].prefix = nil // 검사 중
        #expect(ExternalMatching.match(s, projects: pending) == .waitingForCheck(projectID: pid))
    }

    @Test func targetsUseCheckPrefixAndRealPaths() {
        let env = PMHEnvironment(id: "e", name: "a", pythonPath: "/v/bin/python")
        let registry = Registry(projects: [Project(id: pid, path: "/link/proj", environments: [env])])
        let report = CheckReport(pythonVersion: [3, 13, 1], pytestVersion: "9", fastapiVersion: nil,
                                 pluginInstalled: true, pluginVersion: "0.3.0", prefix: "/v")
        let targets = ExternalMatching.targets(registry: registry, checks: ["e": EnvCheck(status: .ready, report: report, issues: [])],
                                               realPath: { $0.replacingOccurrences(of: "/link", with: "/real") })
        #expect(targets == [ProjectTarget(id: pid, path: "/real/proj", environments: [EnvTarget(id: "e", pythonPath: "/v/bin/python", prefix: "/v")])])
        // 검사 전이면 prefix를 모른다.
        #expect(ExternalMatching.targets(registry: registry, checks: [:])[0].environments[0].prefix == nil)
    }

    @Test func realPathMatchesPythonForPrivateTmp() {
        // Python os.path.realpath("/tmp")는 "/private/tmp"다. Foundation처럼 "/tmp"로 줄이면 비교가 어긋난다.
        #expect(PathTools.realPath("/tmp") == "/private/tmp")
    }
}

// MARK: 생존 확인

@Suite struct LivenessTests {
    @Test func currentProcessIsAliveAndDeadPidIsDead() throws {
        #expect(ProcessLiveness.check(pid: getpid(), startedBy: Date()) == .alive)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run(); p.waitUntilExit()
        #expect(ProcessLiveness.check(pid: p.processIdentifier, startedBy: nil) == .dead)
    }

    @Test func pidStartedAfterSessionStartIsTreatedAsReused() {
        // 이 테스트 프로세스는 1970년 이후에 시작했으므로, 그 시각에 시작한 pytest의 pid일 수 없다.
        #expect(ProcessLiveness.check(pid: getpid(), startedBy: Date(timeIntervalSince1970: 0)) == .dead)
    }
}

// MARK: 합치기

@Suite struct MergeTests {
    let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
    let failed = RunOutcome.incomplete(termination: .unknown, stopped: false, done: 1, total: 3)
    let passed = RunOutcome.launchFailed(message: "app")

    @Test func laterFinishWinsAndSourceIsRecorded() {
        var app = RunSnapshot(results: ["e": passed], elapsed: ["e": 1])
        app.finishedAt["e"] = early
        let ext = ExternalSnapshot(results: ["e": ExternalResult(runID: "x", envID: "e", outcome: failed, elapsed: nil, finishedAt: late)])
        let m = app.merged(external: ext)
        #expect(m.results["e"] == failed && m.sources["e"] == .terminal && m.elapsed["e"] == nil)
        // 앱 결과가 더 늦으면 앱 결과가 남는다.
        app.finishedAt["e"] = Date(timeIntervalSince1970: 300)
        let kept = app.merged(external: ext)
        #expect(kept.results["e"] == passed && kept.sources["e"] == nil)
    }

    @Test func latestStartedExternalRunIsShownPerEnvironment() {
        let a = ExternalActive(runID: "a", envID: "e", projectID: UUID(), phase: .running(done: 1, total: 2), startedAt: early, pid: 1, statusKnown: true)
        var b = a; b.runID = "b"; b.startedAt = late
        let m = RunSnapshot().merged(external: ExternalSnapshot(active: [a, b]))
        #expect(m.external["e"]?.runID == "b")
    }
}

// MARK: 화면 값

@Suite struct ExternalPresentationTests {
    private func check(version: String = "0.3.0", plugin: Bool = true, prefix: String? = "/v") -> EnvCheck {
        Interpreter.interpret(report: CheckReport(pythonVersion: [3, 13, 1], pytestVersion: "9", fastapiVersion: "1",
                                                  pluginInstalled: plugin, pluginVersion: plugin ? version : nil, prefix: prefix),
                              pythonPath: "/v/bin/python", repoPath: "/repo")
    }
    let env = PMHEnvironment(id: "e", name: "pmh-3.13", pythonPath: "/v/bin/python")

    private func active(known: Bool = true) -> ExternalActive {
        ExternalActive(runID: "x", envID: "e", projectID: UUID(), phase: .running(done: 1, total: 3),
                       startedAt: Date(), pid: 4242, statusKnown: known)
    }

    @Test func runningTerminalRunShowsProgressAndKeepsRunButton() {
        var snap = RunSnapshot()
        snap.external["e"] = active()
        let row = ResultPresentation.row(env: env, check: check(), snapshot: snap, selected: true)
        #expect(row.statusText == "터미널 실행 중 1/3")
        #expect(row.tone == .running && row.progressText == "1/3")
        // 앱이 띄운 프로세스가 아니므로 ■가 없고 ▶는 켜져 있다.
        #expect(row.action == .run(enabled: true))
        #expect(row.removeBlockedReason == nil)
    }

    @Test func unknownStatusIsNotCalledRunningAndNeverFails() {
        var snap = RunSnapshot()
        snap.external["e"] = active(known: false)
        let row = ResultPresentation.row(env: env, check: check(), snapshot: snap, selected: true)
        #expect(row.statusText == "터미널 실행 · 상태 확인 불가 (1/3)")
        #expect(row.tone == .attention)
        let d = ResultPresentation.detail(envID: "e", active: nil, outcome: nil, elapsed: nil, blockedReason: nil, external: active(known: false))
        #expect(d.headline == "터미널 실행 · 상태 확인 불가 (1/3)")
        #expect(d.notes.contains { $0.contains("0.3.0") })
    }

    @Test func appRunTakesPrecedenceOverTerminalRunInRow() {
        let app = ActiveRun(runID: "app", envID: "e", projectPath: "/p", phase: .running(done: 0, total: 2), stopping: false)
        var snap = RunSnapshot(actives: ["e": app])
        snap.external["e"] = active()
        let row = ResultPresentation.row(env: env, check: check(), snapshot: snap, selected: true)
        #expect(row.statusText == "실행 중 0/2" && row.action == .stop(enabled: true))
        let d = ResultPresentation.detail(envID: "e", active: snap.actives["e"], outcome: nil, elapsed: nil, blockedReason: nil, external: active())
        #expect(d.notes.contains { $0.contains("터미널 실행도 진행 중") })
    }

    @Test func terminalResultHasSuffixAndNote() {
        let summary = RunSummary(state: "completed", verdict: "failed", exitCode: 1, counts: ["passed": 1, "failed": 1])
        var snap = RunSnapshot(results: ["e": .finished(summary)])
        snap.sources["e"] = .terminal
        #expect(ResultPresentation.row(env: env, check: check(), snapshot: snap, selected: false).statusText == "실패 1 · 터미널")
        let d = ResultPresentation.detail(envID: "e", active: nil, outcome: .finished(summary), elapsed: 2, blockedReason: nil, source: .terminal)
        #expect(d.notes.first == "다른 터미널에서 실행한 결과입니다.")
        #expect(d.counts.first { $0.key == "failed" }?.value == 1)
    }

    @Test func vanishedTerminalRunIsIncompleteNotFailed() {
        let outcome = RunOutcome.incomplete(termination: .unknown, stopped: false, done: 1, total: 3)
        #expect(outcome.title == "미완료 · 프로세스 종료됨(종료 코드 모름) · 1/3 끝남")
        #expect(ResultPresentation.outcomeStatus(outcome) == ("미완료", .attention))
        let d = ResultPresentation.detail(envID: "e", active: nil, outcome: outcome, elapsed: nil, blockedReason: nil, source: .terminal)
        #expect(d.notes.contains { $0.contains("종료 기록 없이 pytest 프로세스가 끝났습니다") })
    }

    @Test func noticeForUnregisteredEnvironmentDisappearsOnceRegistered() {
        let project = Project(path: "/p", environments: [env])
        let run = UnregisteredRun(runID: "x", projectID: project.id, environmentPath: "/Users/me/.venvs/other", seenAt: Date())
        let notice = ResultPresentation.terminalNotice(project: project, unregistered: [run], checks: ["e": check()], home: "/Users/me")
        #expect(notice == "등록하지 않은 Python 환경(~/.venvs/other)에서 실행한 pytest를 감지했습니다. \"+ 환경 추가\"로 등록하면 결과가 보입니다.")
        let registered = ResultPresentation.terminalNotice(project: project, unregistered: [run],
                                                           checks: ["e": check(prefix: "/Users/me/.venvs/other")], home: "/Users/me")
        #expect(registered == nil)
        // 다른 프로젝트의 감지는 이 프로젝트에 보이지 않는다.
        #expect(ResultPresentation.terminalNotice(project: Project(path: "/q"), unregistered: [run], checks: [:]) == nil)
    }

    @Test func buildCarriesNoticeAndSelectsTerminalRunEnvironment() {
        let other = PMHEnvironment(id: "o", name: "other", pythonPath: "/o/bin/python")
        let project = Project(path: "/p", environments: [other, env])
        var snap = RunSnapshot()
        snap.external["e"] = active()
        snap.unregistered = [UnregisteredRun(runID: "u", projectID: project.id, environmentPath: "/x", seenAt: Date())]
        let state = ResultPresentation.build(registry: Registry(projects: [project]), checks: ["e": check(), "o": check()],
                                             snapshot: snap, preferredProjectID: nil, preferredEnvID: nil)
        #expect(state.selectedEnvID == "e") // 터미널에서 돌고 있는 환경을 먼저 보여 준다
        #expect(state.detail?.headline == "터미널 실행 중 1/3")
        #expect(state.terminalNotice?.contains("(/x)") == true)
    }

    @Test func detectionNoteExplainsMissingPluginAndDisabledAutoload() {
        #expect(ManagementPresentation.terminalDetectionNote(nil) == nil)
        #expect(ManagementPresentation.terminalDetectionNote(check(plugin: false))?.contains("플러그인이 없어") == true)
        let ready = ManagementPresentation.terminalDetectionNote(check()) ?? ""
        #expect(ready.contains("PYTEST_DISABLE_PLUGIN_AUTOLOAD=1") && ready.contains("-p no:pytest_menu_helper.plugin")
                && ready.contains("PYTEST_MENU_DISABLE=1"))
        #expect(ManagementPresentation.terminalDetectionNote(check(version: "0.2.0"))?.contains("끝났는지 확인할 수 없습니다") == true)
        // 0.2.0 미만은 구버전 조치 줄이 먼저라 이 안내를 붙이지 않는다.
        #expect(ManagementPresentation.terminalDetectionNote(check(version: "0.1.0")) == nil)
    }

    @Test func plugin020WarnsAboutTerminalButDoesNotBlockRun() {
        let c = check(version: "0.2.0")
        #expect(c.issues.map(\.code) == [.pluginNoTerminalSupport])
        #expect(c.status == .actionNeeded)
        #expect(RunEligibility.reason(for: c) == nil)
        #expect(check().issues.isEmpty)
    }
}

// MARK: 감시기

@Suite struct WatcherTests {
    @Test func externalRunIsLinkedTrackedAndAggregatedOnce() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow() // 빈 폴더에서 첫 읽기(이후 생기는 파일은 새 실행)
        let run = newRunID()
        fx.aggregator.json = fx.aggregator.json.replacingOccurrences(of: "RID", with: run)
        fx.alive = [4242]
        try fx.start(run)
        try fx.teardown(run, "t::a")
        fx.watcher.scanNow()
        let active = try #require(fx.watcher.snapshot.active.first)
        #expect(active.envID == "envA" && active.phase == .running(done: 1, total: 3) && active.statusKnown)
        try fx.teardown(run, "t::b"); try fx.teardown(run, "t::c"); try fx.finish(run)
        fx.watcher.scanNow()
        fx.watcher.scanNow()
        let snap = fx.watcher.snapshot
        #expect(snap.active.isEmpty)
        let result = try #require(snap.results["envA"])
        guard case .finished(let s) = result.outcome else { Issue.record("결과: \(result.outcome)"); return }
        #expect(s.verdict == "failed")
        #expect(abs((result.elapsed ?? 0) - 12.5) < 0.001) // session_start~session_finish 이벤트 시각
        #expect(fx.aggregator.calls.count == 1)
        #expect(fx.aggregator.calls[0][0] == "/venvs/a/bin/python") // 등록한 환경의 집계기로 판정
    }

    @Test func appRunsAndNestedRunsAreNotShown() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow()
        let app = newRunID(), nested = newRunID()
        fx.appRuns = [app]
        fx.alive = [4242]
        try fx.start(app)
        try fx.start(nested, parent: app)
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.active.isEmpty)
        try fx.finish(app); try fx.finish(nested)
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.results.isEmpty)
        #expect(fx.aggregator.calls.isEmpty)
    }

    @Test func killedRunWithoutFinishIsIncomplete() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow()
        let run = newRunID()
        fx.alive = [4242]
        try fx.start(run); try fx.teardown(run, "t::a")
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.active.count == 1)
        fx.alive = [] // kill -9
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.active.isEmpty)
        #expect(fx.watcher.snapshot.results["envA"]?.outcome == .incomplete(termination: .unknown, stopped: false, done: 1, total: 3))
        #expect(fx.aggregator.calls.isEmpty) // 종료 기록이 없으면 집계하지 않는다
    }

    @Test func finishWrittenJustBeforeExitIsAggregatedNotIncomplete() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow()
        let run = newRunID()
        fx.aggregator.json = fx.aggregator.json.replacingOccurrences(of: "RID", with: run)
        fx.alive = [4242]
        try fx.start(run)
        fx.watcher.scanNow()
        // 다음 읽기 전에 종료 이벤트를 쓰고 바로 끝났다.
        try fx.finish(run)
        fx.alive = []
        fx.watcher.scanNow()
        guard case .finished? = fx.watcher.snapshot.results["envA"]?.outcome else {
            Issue.record("결과: \(String(describing: fx.watcher.snapshot.results["envA"]))"); return
        }
    }

    @Test func runWithoutPidStaysUnknownInsteadOfTimingOut() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow()
        let run = newRunID()
        try fx.start(run, pid: nil)
        for _ in 0..<5 { fx.watcher.scanNow() }
        let active = try #require(fx.watcher.snapshot.active.first)
        #expect(!active.statusKnown)
        #expect(fx.watcher.snapshot.results.isEmpty)
    }

    @Test func filesFromBeforeAppStartAreSkippedUnlessStillRunning() throws {
        let fx = try WatchFixture()
        let done = newRunID(), running = newRunID(), vanished = newRunID()
        try fx.start(done, pid: 1); try fx.finish(done)
        try fx.start(running, pid: 2)
        try fx.start(vanished, pid: 3)
        fx.alive = [1, 2]
        fx.watcher.scanNow() // 첫 읽기: 세 파일 모두 앱을 켜기 전 파일
        let snap = fx.watcher.snapshot
        #expect(snap.active.map(\.runID) == [running])
        #expect(snap.results.isEmpty) // 끝난 실행·사라진 실행은 결과로 보이지 않는다
    }

    @Test func unregisteredEnvironmentIsReportedAndNotLinked() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow()
        let run = newRunID()
        fx.alive = [4242]
        try fx.start(run, prefix: "/venvs/other")
        fx.watcher.scanNow()
        let snap = fx.watcher.snapshot
        #expect(snap.active.isEmpty && snap.results.isEmpty)
        #expect(snap.unregistered.map(\.environmentPath) == ["/venvs/other"])
        #expect(snap.unregistered.first?.projectID == fx.projectID)
    }

    @Test func runOutsideProjectsIsIgnored() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow()
        let run = newRunID()
        fx.alive = [4242]
        try fx.start(run, cwd: "/elsewhere")
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot == ExternalSnapshot())
    }

    @Test func runSeenBeforeCheckFinishesIsLinkedAfterTargetsUpdate() throws {
        let fx = try WatchFixture(prefix: nil) // 검사 전
        fx.watcher.scanNow()
        let run = newRunID()
        fx.alive = [4242]
        try fx.start(run)
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.active.isEmpty)
        fx.watcher.updateTargets([ProjectTarget(id: fx.projectID, path: fx.projectPath,
                                                environments: [EnvTarget(id: "envA", pythonPath: "/venvs/a/bin/python", prefix: "/venvs/a")])])
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.active.first?.envID == "envA")
    }

    @Test func removedEnvironmentDropsLiveProgress() throws {
        let fx = try WatchFixture()
        fx.watcher.scanNow()
        let run = newRunID()
        fx.alive = [4242]
        try fx.start(run)
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.active.count == 1)
        fx.watcher.updateTargets([ProjectTarget(id: fx.projectID, path: fx.projectPath, environments: [])])
        fx.watcher.scanNow()
        #expect(fx.watcher.snapshot.active.isEmpty)
    }
}
