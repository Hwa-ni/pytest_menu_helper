import Foundation
import Testing
@testable import PMHCore

private func uuid() -> String { UUID().uuidString.lowercased() }

private func writeText(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

// MARK: 줄 조각과 한글 경계

@Suite struct TailTests {
    @Test func partialLineWaitsForNewline() {
        var s = LineSplitter()
        #expect(s.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        #expect(s.pending == Data("{\"b\"".utf8))
        let rest = s.append(Data(":2}\n".utf8))
        #expect(rest.count == 1)
        #expect(String(decoding: rest[0], as: UTF8.self) == "{\"b\":2}")
        #expect(s.pending.isEmpty)
    }

    @Test func hangulSplitInsideMultibyteCharacterIsNotCorrupted() throws {
        let bytes = Array("{\"m\":\"한글 테스트\"}\n".utf8)
        let cut = try #require(bytes.firstIndex(of: 0xED)) + 1 // '한'(3바이트) 첫 바이트 바로 뒤
        var s = LineSplitter()
        #expect(s.append(Data(bytes[..<cut])).isEmpty)
        let lines = s.append(Data(bytes[cut...]))
        #expect(lines.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: lines[0]) as? [String: String])
        #expect(object["m"] == "한글 테스트")
    }

    @Test func fileTailReadsOnlyNewBytesAndHoldsPartialLine() throws {
        let url = tempDir().appendingPathComponent("e.jsonl")
        var tail = EventTail(url: url)
        #expect(tail.read().isEmpty)
        #expect(!tail.fileSeen) // 파일이 없다(수집 대기)
        let line = Array("{\"m\":\"가나다\"}\n".utf8)
        let cut = try #require(line.firstIndex(of: 0xEA)) + 2 // 한글 중간
        try Data(line[..<cut]).write(to: url)
        #expect(tail.read().isEmpty)
        #expect(tail.fileSeen)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line[cut...]) + Data("{\"n\":1}\n".utf8))
        try handle.close()
        let lines = tail.read()
        #expect(lines.count == 2)
        #expect(String(decoding: lines[0], as: UTF8.self) == "{\"m\":\"가나다\"}")
        #expect(tail.read().isEmpty) // 이미 읽은 부분은 다시 읽지 않는다
    }
}

// MARK: 진행률과 run_id 매칭

@Suite struct ProgressTests {
    private func ev(_ run: String, _ kind: String, _ extra: String = "") -> Data {
        Data("{\"run_id\":\"\(run)\",\"event\":\"\(kind)\"\(extra)}".utf8)
    }

    @Test func countsFinishedTestsNotPhases() {
        let r = uuid()
        var p = RunProgress(runID: r)
        p.ingest(ev(r, "session_start"))
        p.ingest(ev(r, "session_collected", ",\"nodeids\":[\"a\",\"b\",\"c\"]"))
        for phase in ["setup", "call"] { p.ingest(ev(r, "test_report", ",\"nodeid\":\"a\",\"phase\":\"\(phase)\"")) }
        #expect(p.total == 3 && p.done == 0)
        p.ingest(ev(r, "test_report", ",\"nodeid\":\"a\",\"phase\":\"teardown\""))
        p.ingest(ev(r, "test_report", ",\"nodeid\":\"a\",\"phase\":\"teardown\"")) // 같은 테스트 중복은 1건
        p.ingest(ev(r, "test_report", ",\"nodeid\":\"b\",\"phase\":\"teardown\",\"occurrence\":2"))
        #expect(p.done == 2)
        #expect(!p.sawFinish)
        p.ingest(ev(r, "session_finish", ",\"exit_code\":0"))
        #expect(p.sawFinish)
    }

    @Test func eventsWithOtherRunIDAreIgnoredAndCounted() {
        let mine = uuid(), other = uuid()
        var p = RunProgress(runID: mine)
        p.ingest(ev(mine, "session_start"))
        p.ingest(ev(other, "test_report", ",\"nodeid\":\"x\",\"phase\":\"teardown\""))
        p.ingest(ev(other, "session_finish", ",\"exit_code\":0"))
        p.ingest(Data("not json".utf8))
        #expect(p.done == 0)
        #expect(!p.sawFinish)
        #expect(p.matchedEvents == 1)
        #expect(p.foreignEvents == 2)
        #expect(p.malformedLines == 1)
    }

    @Test func phaseText() {
        #expect(RunPhase.waitingForEvents.text == "수집 대기")
        #expect(RunPhase.running(done: 12, total: 40).text == "실행 중 12/40")
    }
}

// MARK: 정리

@Suite struct CleanerTests {
    @Test func removesOnlyOldRunFilesAndKeepsNewest() throws {
        let dir = tempDir()
        let fm = FileManager.default
        var runFiles: [String] = []
        let base = Date()
        for i in 0..<8 {
            let name = "\(uuid()).jsonl"
            let url = dir.appendingPathComponent(name)
            try writeText("x", to: url)
            try fm.setAttributes([.modificationDate: base.addingTimeInterval(Double(-i * 10))], ofItemAtPath: url.path)
            runFiles.append(name) // i가 클수록 오래됨
        }
        // 대상이 아닌 것들: 다른 확장자, 아무 이름, 대문자 UUID, 폴더, 심볼릭 링크, 가짜 이름
        let others = ["notes.jsonl", "\(uuid()).log", "\(uuid().uppercased()).jsonl", "custom-events.jsonl",
                      "\(uuid()).jsonl.bak", "README.md"]
        for name in others {
            let url = dir.appendingPathComponent(name)
            try writeText("keep", to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
        }
        let folder = dir.appendingPathComponent("\(uuid()).jsonl")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let outside = tempDir().appendingPathComponent("target.txt")
        try writeText("t", to: outside)
        let link = dir.appendingPathComponent("\(uuid()).jsonl")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        for u in [folder, link] { try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: u.path) }

        let removed = FileCleaner.prune(directory: dir, fileExtension: "jsonl", keep: 5)
        #expect(Set(removed) == Set(runFiles[5...]))
        for name in runFiles[..<5] { #expect(fm.fileExists(atPath: dir.appendingPathComponent(name).path)) }
        for name in others { #expect(fm.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name)은 지우면 안 됩니다") }
        #expect(fm.fileExists(atPath: folder.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(fm.fileExists(atPath: outside.path))
    }

    @Test func protectedRunSurvivesAndFewerThanKeepRemovesNothing() throws {
        let dir = tempDir()
        let names = (0..<3).map { _ in "\(uuid()).log" }
        for (i, n) in names.enumerated() {
            let url = dir.appendingPathComponent(n)
            try writeText("x", to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-i * 10))], ofItemAtPath: url.path)
        }
        #expect(FileCleaner.prune(directory: dir, fileExtension: "log", keep: 5).isEmpty)
        let removed = FileCleaner.prune(directory: dir, fileExtension: "log", keep: 1, protecting: [names[2]])
        #expect(removed == [names[1]])
    }

    @Test func defaultKeepIs50() { #expect(FileCleaner.defaultKeep == 50) }
}

// MARK: 환경 검사(플러그인 버전)와 실행 가능 여부

@Suite struct EligibilityTests {
    private func check(_ report: CheckReport) -> EnvCheck {
        Interpreter.interpret(report: report, pythonPath: "/p", repoPath: "/repo")
    }
    private func report(plugin: Bool = true, version: String? = "0.2.0", pytest: String? = "9.0") -> CheckReport {
        CheckReport(pythonVersion: [3, 13, 1], pytestVersion: pytest, fastapiVersion: "0.1",
                    pluginInstalled: plugin, pluginVersion: version)
    }

    @Test func oldPluginIsActionNeededAndBlocksRun() {
        for old in ["0.1.0", nil] as [String?] {
            let c = check(report(version: old))
            #expect(c.status == .actionNeeded)
            #expect(c.issues.map(\.code) == [.pluginOutdated])
            #expect(c.issues[0].fixCommand?.contains("uv pip install") == true)
            #expect(RunEligibility.reason(for: c) != nil)
        }
    }

    @Test func versionComparison() {
        #expect(Interpreter.pluginSupportsRunID("0.2.0"))
        #expect(Interpreter.pluginSupportsRunID("0.10.1"))
        #expect(Interpreter.pluginSupportsRunID("1.0"))
        #expect(Interpreter.pluginSupportsRunID("0.2.0.dev1"))
        #expect(!Interpreter.pluginSupportsRunID("0.1.9"))
        #expect(!Interpreter.pluginSupportsRunID("garbage"))
        #expect(!Interpreter.pluginSupportsRunID(nil))
    }

    @Test func reasonCases() {
        #expect(RunEligibility.reason(for: nil) != nil)
        #expect(RunEligibility.reason(for: check(report())) == nil)
        #expect(RunEligibility.reason(for: check(report(plugin: false, version: nil))) != nil)
        #expect(RunEligibility.reason(for: check(report(pytest: nil))) != nil)
        // FastAPI 누락만으로는 실행을 막지 않는다(경고).
        let noFastapi = CheckReport(pythonVersion: [3, 13, 1], pytestVersion: "9", fastapiVersion: nil,
                                    pluginInstalled: true, pluginVersion: "0.2.0")
        #expect(RunEligibility.reason(for: check(noFastapi)) == nil)
    }
}

// MARK: 실행 컨트롤러(가짜 python 스크립트로 검증)

private final class Fixture {
    let dir = tempDir()
    let paths: AppPaths
    let python: URL
    let project: URL

    init(mode: String, aggregate: String = "") throws {
        paths = AppPaths(base: dir.appendingPathComponent("data"))
        project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        python = dir.appendingPathComponent("fake-python")
        try writeText(Fixture.script, to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try writeText(mode, to: dir.appendingPathComponent("mode"))
        try writeText(aggregate, to: dir.appendingPathComponent("agg.json"))
    }

    // 실제 python 대신 쓰는 셸 스크립트. 인수가 -I면 집계 호출, 아니면 pytest 실행으로 본다.
    static let script = """
    #!/bin/sh
    here="$(dirname "$0")"
    if [ "$1" = "-I" ]; then cat "$here/agg.json"; exit "$(cat "$here/agg.exit" 2>/dev/null || echo 0)"; fi
    mode="$(cat "$here/mode")"
    f="$PYTEST_MENU_EVENTS_DIR/$PMH_RUN_ID.jsonl"
    ev() { printf '{"run_id":"%s","event":"%s"%s}\\n' "${RID:-$PMH_RUN_ID}" "$1" "$2" >> "$f"; }
    echo "env: disable=[$PYTEST_DISABLE_PLUGIN_AUTOLOAD] menu=[$PYTEST_MENU_DISABLE] envid=[$PMH_ENV_ID] cwd=$(pwd)"
    case "$mode" in
      ok)
        ev session_start; ev session_collected ',"nodeids":["a","b"]'
        sleep 0.6
        ev test_report ',"nodeid":"a","phase":"teardown"'; ev test_report ',"nodeid":"b","phase":"teardown"'
        ev session_finish ',"exit_code":1' ;;
      hang)
        trap '' INT
        ev session_start; ev session_collected ',"nodeids":["a"]'
        while true; do sleep 0.1; done ;;
      noevents) echo "boom: cannot import plugin"; exit 3 ;;
      killed) ev session_start; kill -9 $$ ;;
      foreign) (RID=00000000-0000-4000-8000-000000000000; ev session_start); ev session_start; (RID=00000000-0000-4000-8000-000000000000; ev session_finish ',"exit_code":0') ;;
    esac
    """

    func controller(grace: TimeInterval = 5) -> RunController {
        RunController(paths: paths, pollInterval: 0.05, stopGrace: grace,
                      notifyQueue: DispatchQueue(label: "test.notify"), onChange: { _ in })
    }
}

private func waitUntil(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return cond()
}

@Suite struct ControllerTests {
    static let aggJSON = "{\"state\":\"completed\",\"verdict\":\"failed\",\"exit_code\":1,\"counts\":{\"passed\":1,\"failed\":1}}"

    @Test func childEnvironmentDropsDisablersAndSetsIDs() {
        let env = RunController.childEnvironment(
            envID: "E", runID: "R", eventsDir: URL(fileURLWithPath: "/ev"),
            base: ["PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1", "PYTEST_MENU_DISABLE": "1", "KEEP": "v", "PMH_RUN_ID": "old"])
        #expect(env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] == nil)
        #expect(env["PYTEST_MENU_DISABLE"] == nil)
        #expect(env["PMH_ENV_ID"] == "E" && env["PMH_RUN_ID"] == "R")
        #expect(env["KEEP"] == "v")
    }

    @Test func successfulRunIsAggregatedOncePerRunAndLogsToFile() async throws {
        let fx = try Fixture(mode: "ok", aggregate: Self.aggJSON)
        let c = fx.controller()
        guard case .started(let runID) = c.start(envID: "env1", pythonPath: fx.python.path, projectPath: fx.project.path) else {
            Issue.record("시작하지 못함"); return
        }
        #expect(c.snapshot.active?.runID == runID)
        #expect(await waitUntil { c.snapshot.active == nil })
        guard case .finished(let s)? = c.snapshot.results["env1"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["env1"]))"); return
        }
        #expect(s.verdict == "failed" && s.title == "실패")
        #expect(RunOutcome.finished(s).title == "실패 · 통과 1 · 실패 1")
        let log = try String(contentsOf: fx.paths.logFile(runID: runID), encoding: .utf8)
        #expect(log.contains("disable=[] menu=[]"))
        #expect(log.contains("envid=[env1]"))
        #expect(log.contains(fx.project.path)) // 프로젝트 폴더가 cwd
        #expect(FileManager.default.fileExists(atPath: fx.paths.eventsFile(runID: runID).path))
    }

    @Test func progressShowsDoneOverTotalWhileRunning() async throws {
        let fx = try Fixture(mode: "ok", aggregate: Self.aggJSON)
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.active?.phase == .running(done: 0, total: 2) })
        #expect(await waitUntil { c.snapshot.active == nil })
    }

    @Test func secondRunIsRejectedWhileOneIsActive() async throws {
        let fx = try Fixture(mode: "hang")
        let c = fx.controller(grace: 0.3)
        guard case .started = c.start(envID: "e1", pythonPath: fx.python.path, projectPath: fx.project.path) else {
            Issue.record("시작하지 못함"); return
        }
        #expect(c.start(envID: "e2", pythonPath: fx.python.path, projectPath: fx.project.path) == .alreadyRunning)
        #expect(c.start(envID: "e1", pythonPath: fx.python.path, projectPath: fx.project.path) == .alreadyRunning)
        #expect(await waitUntil { c.snapshot.active?.phase == .running(done: 0, total: 1) })
        c.stop() // SIGINT를 무시하는 가짜라 유예 시간 뒤 강제 종료된다
        #expect(await waitUntil { c.snapshot.active == nil })
        guard case .incomplete(let t, let stopped, _, _)? = c.snapshot.results["e1"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e1"]))"); return
        }
        #expect(t == .signal(9) && stopped)
        // 끝난 뒤에는 다시 시작할 수 있다.
        if case .started = c.start(envID: "e2", pythonPath: fx.python.path, projectPath: fx.project.path) {} else {
            Issue.record("끝난 뒤에는 새 실행이 가능해야 합니다")
        }
        c.stop()
        #expect(await waitUntil { c.snapshot.active == nil })
    }

    @Test func missingFinishEventIsIncompleteWithSignal() async throws {
        let fx = try Fixture(mode: "killed")
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.active == nil })
        guard case .incomplete(let t, let stopped, _, _)? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(t == .signal(9) && !stopped)
        #expect(c.snapshot.results["e"]?.title.hasPrefix("미완료 · 시그널 9(KILL)") == true)
    }

    @Test func noEventFileAfterExitIsCollectionFailureWithLogTail() async throws {
        let fx = try Fixture(mode: "noevents")
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.active == nil })
        guard case .collectionFailed(let t, let tail)? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(t == .exit(3))
        #expect(tail == "boom: cannot import plugin")
        #expect(c.snapshot.results["e"]?.detail == "로그 마지막 줄: boom: cannot import plugin")
    }

    @Test func eventsFromAnotherRunAreNotMixedIn() async throws {
        let fx = try Fixture(mode: "foreign", aggregate: Self.aggJSON)
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.active == nil })
        guard case .eventsMixed(let n)? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(n == 2)
    }

    @Test func aggregationFailureIsAnErrorNotAVerdict() async throws {
        let fx = try Fixture(mode: "ok", aggregate: "No module named pytest_menu_helper.aggregate")
        try writeText("1", to: fx.dir.appendingPathComponent("agg.exit"))
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.active == nil })
        guard case .aggregationFailed? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(c.snapshot.results["e"]?.title == "집계 오류")
    }

    @Test func missingProjectFolderIsLaunchFailure() async throws {
        let fx = try Fixture(mode: "ok")
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.dir.appendingPathComponent("nope").path)
        #expect(await waitUntil { c.snapshot.active == nil })
        guard case .launchFailed? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
    }

    @Test func runEndCleanupKeepsOnlyNewestAndOnlyRunFiles() async throws {
        let fx = try Fixture(mode: "ok", aggregate: Self.aggJSON)
        try fx.paths.ensureDirectories()
        let custom = fx.paths.eventsDir.appendingPathComponent("custom.jsonl")
        try writeText("keep", to: custom)
        for i in 0..<5 {
            let u = fx.paths.eventsDir.appendingPathComponent("\(uuid()).jsonl")
            try writeText("old", to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(i))], ofItemAtPath: u.path)
        }
        let c = RunController(paths: fx.paths, pollInterval: 0.05, keep: 2,
                              notifyQueue: DispatchQueue(label: "t"), onChange: { _ in })
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.active == nil })
        let names = try FileManager.default.contentsOfDirectory(atPath: fx.paths.eventsDir.path)
        #expect(names.filter { FileCleaner.isRunFile($0, ext: "jsonl") }.count == 2)
        #expect(names.contains("custom.jsonl"))
    }
}

/// 결과 문구에 미실행 수가 나오는지 확인한다. 중지한 실행에서 수집 수와 합계가 안 맞는 이유를 보여 주기 위함이다.
@Suite struct NotRunTextTests {
    @Test func interruptedRunShowsNotRunCount() {
        let s = RunSummary(state: "interrupted", verdict: nil, exitCode: 2,
                           counts: ["passed": 2, "failed": 0, "incomplete": 1, "not_run": 2])
        #expect(s.countsText == "통과 2 · 실패 0 · 미완료 1 · 미실행 2")
        #expect(RunOutcome.finished(s).title == "중단됨 · 통과 2 · 실패 0 · 미완료 1 · 미실행 2")
    }

    @Test func zeroNotRunIsHidden() {
        // 구버전 집계기처럼 not_run 키가 없거나 0이면 문구에 넣지 않는다.
        let s = RunSummary(state: "completed", verdict: "passed", exitCode: 0, counts: ["passed": 3, "not_run": 0])
        #expect(s.countsText == "통과 3 · 실패 0")
    }
}
