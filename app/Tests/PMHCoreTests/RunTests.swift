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
    private func report(plugin: Bool = true, version: String? = "0.3.0", pytest: String? = "9.0") -> CheckReport {
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
                                    pluginInstalled: true, pluginVersion: "0.3.0")
        #expect(RunEligibility.reason(for: check(noFastapi)) == nil)
    }
}

// MARK: 실행 컨트롤러(가짜 python 스크립트로 검증)

private final class Fixture {
    let dir = tempDir()
    let paths: AppPaths
    let python: URL
    let project: URL
    /// 이 픽스처로 만든 컨트롤러. 테스트가 끝나 픽스처가 사라질 때 자식을 모두 정리하려고 쥐고 있다.
    private var controllers: [RunController] = []

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
    // 동작은 mode-<환경 id> 파일이 있으면 그 값, 없으면 mode 파일 값을 따른다(9단계: 환경마다 다르게 돌리기 위함).
    // 집계 출력은 agg-<스크립트 파일 이름>.json이 있으면 그 값, 없으면 agg.json이다. 집계 호출에는 PMH_ENV_ID가 없어서
    // (앱이 집계기에 환경 변수를 넘기지 않는다) 환경마다 다른 판정을 주려면 python 경로(파일 이름)로 가려야 한다.
    static let script = """
    #!/bin/sh
    here="$(dirname "$0")"
    if [ "$1" = "-I" ]; then
      agg="$here/agg-$(basename "$0").json"; [ -f "$agg" ] || agg="$here/agg.json"
      cat "$agg"; exit "$(cat "$here/agg.exit" 2>/dev/null || echo 0)"
    fi
    mode="$(cat "$here/mode-$PMH_ENV_ID" 2>/dev/null || cat "$here/mode")"
    f="$PYTEST_MENU_EVENTS_DIR/$PMH_RUN_ID.jsonl"
    ev() { printf '{"run_id":"%s","event":"%s"%s}\\n' "${RID:-$PMH_RUN_ID}" "$1" "$2" >> "$f"; }
    echo "env: disable=[$PYTEST_DISABLE_PLUGIN_AUTOLOAD] menu=[$PYTEST_MENU_DISABLE] envid=[$PMH_ENV_ID] cwd=$(pwd)"
    case "$mode" in
      ok)
        ev session_start; ev session_collected ',"nodeids":["a","b"]'
        sleep 0.6
        ev test_report ',"nodeid":"a","phase":"teardown"'; ev test_report ',"nodeid":"b","phase":"teardown"'
        ev session_finish ',"exit_code":1' ;;
      # hang·intexit는 끝없이 도는 대신 60초 뒤 스스로 끝난다. 테스트 프로그램이 비정상 종료해
      # 정리 코드가 돌지 못해도 가짜 pytest가 영원히 남지 않게 하는 마지막 안전장치다(테스트는 모두 60초 안에 끝난다).
      hang)
        trap '' INT
        ev session_start; ev session_collected ',"nodeids":["a"]'
        i=0; while [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done; exit 7 ;;
      intexit)
        # SIGINT를 받으면 코드 2로 끝난다. 종료 직전 중지가 SIGKILL이 아니라 SIGINT로 끝냈는지 가리기 위함이다.
        trap 'exit 2' INT
        ev session_start; ev session_collected ',"nodeids":["a"]'
        i=0; while [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done; exit 7 ;;
      noevents) echo "boom: cannot import plugin"; exit 3 ;;
      killed) ev session_start; kill -9 $$ ;;
      foreign) (RID=00000000-0000-4000-8000-000000000000; ev session_start); ev session_start; (RID=00000000-0000-4000-8000-000000000000; ev session_finish ',"exit_code":0') ;;
    esac
    """

    /// 테스트가 어떻게 끝나든(중간 실패로 일찍 return해도) 남은 가짜 pytest를 끝낸다.
    /// 필요한 이유: 일반 stop은 work 큐의 지연 SIGKILL에 기대는데, 실패한 테스트는 stop을 부르기 전에 끝나거나
    /// work 큐가 막혀(집계가 멈춘 경우) SIGKILL이 나가기 전에 테스트 프로그램이 끝날 수 있다. 그러면 SIGINT를
    /// 무시하는 hang 자식이 launchd 밑으로 옮겨 계속 남는다(9단계에서 실제로 남았다).
    /// stopForTermination은 work 큐를 거치지 않고 바로 SIGINT·SIGKILL을 보내므로 여기서 쓴다(대기 0초, 확인 최대 0.5초).
    deinit {
        for c in controllers { c.stopForTermination(timeout: 0) }
    }

    /// 집계 결과가 다른 가짜 python을 하나 더 만든다(9단계: 환경마다 다른 판정).
    /// - Parameters: name(새 파일 이름), aggregate(그 python으로 집계를 부르면 돌려줄 JSON).
    /// - Returns: 새 가짜 python 경로. pytest 실행 동작은 원래 스크립트와 같다(mode 파일 규칙).
    func python(named name: String, aggregate: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try writeText(Fixture.script, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try writeText(aggregate, to: dir.appendingPathComponent("agg-\(name).json"))
        return url
    }

    /// 한 환경만 다른 동작으로 돌린다. 매개변수: mode(ok, hang 등), env(환경 id).
    func setMode(_ mode: String, env: String) throws {
        try writeText(mode, to: dir.appendingPathComponent("mode-\(env)"))
    }

    /// 매개변수: grace(낱개 중지 유예), limit(동시 실행 상한), keep(정리 때 남길 수),
    /// notifyQueue·onChange(상태 알림을 받을 직렬 큐와 함수. 알림 순서를 보는 테스트만 넘긴다).
    func controller(grace: TimeInterval = 5, limit: Int = RunController.maxConcurrentRuns,
                    keep: Int = FileCleaner.defaultKeep,
                    notifyQueue: DispatchQueue = DispatchQueue(label: "test.notify"),
                    onChange: @escaping (RunSnapshot) -> Void = { _ in }) -> RunController {
        let c = RunController(paths: paths, pollInterval: 0.05, stopGrace: grace, keep: keep, maxConcurrentRuns: limit,
                              notifyQueue: notifyQueue, onChange: onChange)
        controllers.append(c)
        return c
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
        #expect(c.snapshot.actives["env1"]?.runID == runID)
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        guard case .finished(let s)? = c.snapshot.results["env1"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["env1"]))"); return
        }
        #expect(s.verdict == "failed" && s.title == "실패")
        #expect(RunOutcome.finished(s).title == "실패 · 통과 1 · 실패 1")
        // 팝오버의 소요 시간 링이 쓰는 값. 프로세스를 띄운 뒤 끝날 때까지라 0 이상이어야 한다.
        #expect((c.snapshot.elapsed["env1"] ?? -1) >= 0)
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
        #expect(await waitUntil { c.snapshot.actives["e"]?.phase == .running(done: 0, total: 2) })
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
    }

    /// 한 환경에는 동시에 1건만 허용한다. 같은 환경을 다시 누르면 거절하고, 끝난 뒤에는 다시 시작할 수 있다.
    @Test func sameEnvironmentTwiceIsRejected() async throws {
        let fx = try Fixture(mode: "hang")
        let c = fx.controller(grace: 0.3)
        guard case .started = c.start(envID: "e1", pythonPath: fx.python.path, projectPath: fx.project.path) else {
            Issue.record("시작하지 못함"); return
        }
        #expect(c.start(envID: "e1", pythonPath: fx.python.path, projectPath: fx.project.path) == .alreadyRunning)
        #expect(c.snapshot.actives.count == 1)
        #expect(await waitUntil { c.snapshot.actives["e1"]?.phase == .running(done: 0, total: 1) })
        #expect(c.childPIDs.count == 1) // 거절한 요청은 자식을 띄우지 않았다
        c.stop(envID: "e1") // SIGINT를 무시하는 가짜라 유예 시간 뒤 강제 종료된다
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        guard case .incomplete(let t, let stopped, _, _)? = c.snapshot.results["e1"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e1"]))"); return
        }
        #expect(t == .signal(9) && stopped)
        // 끝난 뒤에는 다시 시작할 수 있다.
        if case .started = c.start(envID: "e1", pythonPath: fx.python.path, projectPath: fx.project.path) {} else {
            Issue.record("끝난 뒤에는 새 실행이 가능해야 합니다")
        }
        c.stop(envID: "e1")
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
    }

    @Test func missingFinishEventIsIncompleteWithSignal() async throws {
        let fx = try Fixture(mode: "killed")
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
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
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
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
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
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
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        guard case .aggregationFailed? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(c.snapshot.results["e"]?.title == "집계 오류")
    }

    @Test func missingProjectFolderIsLaunchFailure() async throws {
        let fx = try Fixture(mode: "ok")
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.dir.appendingPathComponent("nope").path)
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
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
        let c = fx.controller(keep: 2)
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        let names = try FileManager.default.contentsOfDirectory(atPath: fx.paths.eventsDir.path)
        #expect(names.filter { FileCleaner.isRunFile($0, ext: "jsonl") }.count == 2)
        #expect(names.contains("custom.jsonl"))
    }
}

/// 앱 종료 전용 동기 중지(stopForTermination)를 확인한다.
/// 핵심은 "반환한 시점에 이미 신호가 나갔고 자식이 끝났는가"이다. 앱은 반환 직후 프로세스를 끝내므로
/// 비동기로 미뤄진 신호는 의미가 없다. 그래서 반환 직후의 상태를 바로 확인한다(기다리지 않음).
@Suite struct TerminationStopTests {
    /// 자식 pid가 아직 살아 있는지(좀비 포함). 회수되기 전 좀비도 kill(pid, 0)이 성공하므로
    /// "끝났다"는 판단은 Process.isRunning과 결과 기록으로 한다. 이 함수는 시작 확인에만 쓴다.
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func idleControllerReturnsImmediately() {
        let c = RunController(paths: AppPaths(base: tempDir()), notifyQueue: DispatchQueue(label: "t"), onChange: { _ in })
        let t0 = Date()
        #expect(c.stopForTermination(timeout: 3))
        #expect(Date().timeIntervalSince(t0) < 0.5)
    }

    @Test func sigintIsSentBeforeReturningAndChildExitsGracefully() async throws {
        let fx = try Fixture(mode: "intexit")
        let c = fx.controller()
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.actives["e"]?.phase == .running(done: 0, total: 1) })
        let pid = try #require(c.childPID(envID: "e"))
        #expect(alive(pid))
        let t0 = Date()
        #expect(c.stopForTermination(timeout: 3)) // 반환 시점에 이미 끝나 있어야 한다
        #expect(Date().timeIntervalSince(t0) < 2) // SIGINT로 바로 끝나므로 기다림 상한까지 가지 않는다
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        guard case .incomplete(let t, _, _, _)? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(t == .exit(2)) // SIGKILL(시그널 9)이 아니라 SIGINT 처리로 끝났다
    }

    @Test func childIgnoringSigintIsKilledWithinTimeout() async throws {
        let fx = try Fixture(mode: "hang")
        let c = fx.controller(grace: 60) // 일반 stop의 유예 시간이 끼어들지 않게 길게 둔다
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.actives["e"]?.phase == .running(done: 0, total: 1) })
        let t0 = Date()
        #expect(c.stopForTermination(timeout: 0.5))
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed >= 0.4 && elapsed < 1.5) // SIGINT 뒤 0.5초 기다린 다음 SIGKILL
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        guard case .incomplete(let t, _, _, _)? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(t == .signal(9))
    }

    /// 메인 스레드에서 불러도 끝나는지 확인한다(앱은 applicationWillTerminate에서 메인으로 부른다).
    /// 종료 확인이 메인 런루프나 work 큐에 기대면 여기서 멈춘다.
    @MainActor @Test func worksWhenCalledOnMainThread() async throws {
        let fx = try Fixture(mode: "hang")
        let c = fx.controller(grace: 60)
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        // 진행 줄이 나올 때까지 기다린다. 가짜 스크립트가 SIGINT 무시(trap)를 걸기 전에 신호가 가면
        // 기본 동작으로 바로 끝나 버려, 기다림과 SIGKILL 경로를 확인하지 못한다.
        #expect(await waitUntil { c.snapshot.actives["e"]?.phase == .running(done: 0, total: 1) })
        #expect(pthread_main_np() != 0) // 정말 메인 스레드에서 부르는지(Thread.isMainThread는 async 문맥에서 쓸 수 없다)
        let t0 = Date()
        #expect(c.stopForTermination(timeout: 0.3))
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed >= 0.25 && elapsed < 1.5) // SIGINT 뒤 0.3초 기다리고 SIGKILL로 끝냈다
    }

    @Test func timeoutIsCappedSoMainThreadIsNotBlockedLong() async throws {
        let fx = try Fixture(mode: "hang")
        let c = fx.controller(grace: 60)
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        // 위 테스트와 같은 이유로 trap이 걸린 뒤(진행 줄이 나온 뒤)에 부른다.
        #expect(await waitUntil { c.snapshot.actives["e"]?.phase == .running(done: 0, total: 1) })
        let t0 = Date()
        #expect(c.stopForTermination(timeout: 1000))
        // 1000초를 달라고 해도 상한 5초만 기다리고, SIGKILL 확인 0.5초 안에 돌아온다.
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed >= RunController.maxTerminationWait - 0.1)
        #expect(elapsed < RunController.maxTerminationWait + 1)
    }

    @Test func noNewRunIsLaunchedAfterTerminationStarts() async throws {
        let fx = try Fixture(mode: "hang")
        let c = fx.controller()
        #expect(c.stopForTermination())
        // 종료가 시작된 뒤의 시작 요청은 자식을 띄우지 않고 실행 오류로 끝난다.
        _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        guard case .launchFailed? = c.snapshot.results["e"] else {
            Issue.record("결과: \(String(describing: c.snapshot.results["e"]))"); return
        }
        #expect(c.childPIDs.isEmpty)
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

// MARK: 9단계 동시 실행(설계 5절 단위 테스트 1·2·3·7)

/// 여러 환경 동시 실행을 확인한다. 가짜 python은 mode-<환경 id> 파일로 환경마다 다르게 움직인다.
/// 핵심: 한 환경의 시작·중지·실패가 그 환경 키만 바꾸고, 다른 환경의 실행·프로세스·진행은 그대로여야 한다.
@Suite struct ConcurrentRunTests {
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// 1. 두 환경을 동시에 시작하면 둘 다 받아들이고, 실제로 겹쳐 돈 뒤 각자 결과를 남긴다.
    @Test func twoEnvironmentsRunConcurrently() async throws {
        let fx = try Fixture(mode: "ok", aggregate: ControllerTests.aggJSON)
        let c = fx.controller()
        guard case .started(let runA) = c.start(envID: "a", pythonPath: fx.python.path, projectPath: fx.project.path),
              case .started(let runB) = c.start(envID: "b", pythonPath: fx.python.path, projectPath: fx.project.path) else {
            Issue.record("두 환경 모두 시작해야 합니다"); return
        }
        #expect(runA != runB)
        // 두 실행이 같은 순간에 함께 "실행 중"이었는지 본다(가짜 ok는 0.6초 동안 0/2에 머문다).
        #expect(await waitUntil {
            let s = c.snapshot
            return s.actives["a"]?.phase == .running(done: 0, total: 2) && s.actives["b"]?.phase == .running(done: 0, total: 2)
        })
        #expect(c.childPIDs.count == 2)
        #expect(Set(c.childPIDs.values).count == 2) // 서로 다른 자식 프로세스
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        let s = c.snapshot
        for env in ["a", "b"] {
            guard case .finished? = s.results[env] else { Issue.record("\(env) 결과: \(String(describing: s.results[env]))"); continue }
        }
        #expect(s.runIDs == ["a": runA, "b": runB])
        #expect(s.batchIDs.isEmpty && s.batches.isEmpty) // 낱개 실행은 묶음이 아니다
        // 이벤트 파일도 실행마다 따로다.
        for run in [runA, runB] { #expect(FileManager.default.fileExists(atPath: fx.paths.eventsFile(runID: run).path)) }
    }

    /// 1. 제한 초과: 낱개 start는 .limitReached로 거절하고, startAll은 넘치는 환경을 대기 줄에 넣었다가
    /// 자리가 나면 자동으로 시작한다. 묶음은 모든 환경이 끝나야 끝난 것으로 본다.
    @Test func limitRejectsSingleStartAndStartAllQueuesThenAutoStarts() async throws {
        let fx = try Fixture(mode: "hang", aggregate: ControllerTests.aggJSON)
        try fx.setMode("ok", env: "c")
        let c = fx.controller(grace: 0.3, limit: 2)
        let targets = ["a", "b", "c"].map { RunTarget(envID: $0, pythonPath: fx.python.path) }
        let r = c.startAll(envs: targets, projectPath: fx.project.path)
        let batchID = try #require(r.batchID)
        #expect(r.started == ["a", "b"] && r.queued == ["c"] && r.alreadyRunning.isEmpty)
        var s = c.snapshot
        #expect(s.actives["c"]?.phase == .queued && s.actives["c"]?.isQueued == true)
        #expect(s.actives.values.allSatisfy { $0.batchID == batchID })
        #expect(s.runningCount == 2 && s.isAtRunLimit && s.runLimit == 2)
        #expect(s.batches[batchID]?.envIDs == ["a", "b", "c"])
        #expect(s.batches[batchID]?.runIDs == r.runIDs)
        #expect(s.batches[batchID]?.isFinished == false)
        // 자리가 없으면 낱개 ▶는 대기 줄에 넣지 않고 거절한다. 대기 중인 환경 자신은 alreadyRunning이다.
        #expect(c.start(envID: "d", pythonPath: fx.python.path, projectPath: fx.project.path) == .limitReached)
        #expect(c.start(envID: "c", pythonPath: fx.python.path, projectPath: fx.project.path) == .alreadyRunning)
        #expect(c.snapshot.actives["d"] == nil)
        #expect(await waitUntil { c.snapshot.actives["a"]?.phase == .running(done: 0, total: 1)
                                  && c.snapshot.actives["b"]?.phase == .running(done: 0, total: 1) })
        #expect(c.childPIDs.count == 2) // 대기 중인 c는 아직 띄우지 않았다
        // a를 멈추면 자리가 나서 c가 저절로 시작되고 끝난다.
        c.stop(envID: "a")
        #expect(await waitUntil { c.snapshot.results["c"] != nil })
        s = c.snapshot
        guard case .finished? = s.results["c"] else { Issue.record("c 결과: \(String(describing: s.results["c"]))"); return }
        #expect(s.runIDs["c"] == r.runIDs["c"])
        #expect(s.batchIDs["a"] == batchID && s.batchIDs["c"] == batchID)
        #expect(s.actives["b"]?.phase == .running(done: 0, total: 1)) // b는 그대로 돈다
        #expect(s.batches[batchID]?.isFinished == false && s.batches[batchID]?.finishedAt == nil)
        // 다시 [모두 실행]해도 실행 중인 b는 빠지고, 넣을 환경이 없으니 묶음을 만들지 않는다.
        let again = c.startAll(envs: [RunTarget(envID: "b", pythonPath: fx.python.path)], projectPath: fx.project.path)
        #expect(again.batchID == nil && again.alreadyRunning == ["b"])
        c.stop(envID: "b")
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        s = c.snapshot
        let batch = try #require(s.batches[batchID])
        #expect(batch.isFinished && batch.finishedAt != nil)
        #expect(batch.completedEnvIDs == ["a", "b", "c"] && batch.cancelledEnvIDs.isEmpty)
        #expect(s.batchIDs == ["a": batchID, "b": batchID, "c": batchID])
    }

    /// ■로 대기를 취소하면 실행하지 않고 결과도 남기지 않는다. [모두 중지]는 대기 줄을 먼저 비워,
    /// 실행 중인 것을 멈춘 뒤 대기 환경이 시작되지 않는다.
    @Test func cancelQueuedAndStopAllNeverLaunchesQueued() async throws {
        let fx = try Fixture(mode: "hang", aggregate: ControllerTests.aggJSON)
        for env in ["b", "c", "d"] { try fx.setMode("ok", env: env) }
        let c = fx.controller(grace: 0.3, limit: 1)
        let r = c.startAll(envs: ["a", "b", "c", "d"].map { RunTarget(envID: $0, pythonPath: fx.python.path) },
                           projectPath: fx.project.path)
        let batchID = try #require(r.batchID)
        #expect(r.started == ["a"] && r.queued == ["b", "c", "d"])
        // 대기 취소는 바로(동기로) 반영된다. 프로세스가 없으니 기다릴 것이 없다.
        c.stop(envID: "d")
        #expect(c.snapshot.actives["d"] == nil)
        #expect(c.snapshot.batches[batchID]?.cancelledEnvIDs == ["d"])
        #expect(await waitUntil { c.snapshot.actives["a"]?.phase == .running(done: 0, total: 1) })
        c.stopAll()
        #expect(c.snapshot.actives["b"] == nil && c.snapshot.actives["c"] == nil) // 대기 줄은 즉시 비었다
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        // a가 끝난 뒤에도 b·c가 시작되지 않았는지, 조금 더 기다려 확인한다.
        try await Task.sleep(nanoseconds: 400_000_000)
        let s = c.snapshot
        #expect(s.actives.isEmpty && c.childPIDs.isEmpty)
        #expect(s.results["b"] == nil && s.results["c"] == nil && s.results["d"] == nil)
        guard case .incomplete(let t, let stopped, _, _)? = s.results["a"] else {
            Issue.record("a 결과: \(String(describing: s.results["a"]))"); return
        }
        #expect(t == .signal(9) && stopped)
        // 결과가 남은 a가 묶음을 가리키므로 묶음은 지워지지 않고 끝남으로 남는다.
        let batch = try #require(s.batches[batchID])
        #expect(batch.isFinished && batch.completedEnvIDs == ["a"] && batch.cancelledEnvIDs == ["b", "c", "d"])
    }

    /// 2. 한 환경의 SIGKILL(스스로 kill -9)·launchFailed·stop이 다른 환경의 상태·프로세스를 바꾸지 않는다.
    @Test func failureStopAndLaunchFailureTouchOnlyTheirEnvironment() async throws {
        let fx = try Fixture(mode: "hang", aggregate: ControllerTests.aggJSON)
        try fx.setMode("killed", env: "k")
        let c = fx.controller(grace: 0.3)
        _ = c.start(envID: "a", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.actives["a"]?.phase == .running(done: 0, total: 1) })
        let before = try #require(c.snapshot.actives["a"])
        let pidA = try #require(c.childPID(envID: "a"))

        // SIGKILL로 끝나는 환경 k와, 폴더가 없어 시작하지 못하는 환경 x.
        _ = c.start(envID: "k", pythonPath: fx.python.path, projectPath: fx.project.path)
        _ = c.start(envID: "x", pythonPath: fx.python.path, projectPath: fx.dir.appendingPathComponent("nope").path)
        #expect(await waitUntil { c.snapshot.results["k"] != nil && c.snapshot.results["x"] != nil })
        var s = c.snapshot
        guard case .incomplete(let tk, let stoppedK, _, _)? = s.results["k"] else { Issue.record("k: \(String(describing: s.results["k"]))"); return }
        #expect(tk == .signal(9) && !stoppedK)
        guard case .launchFailed? = s.results["x"] else { Issue.record("x: \(String(describing: s.results["x"]))"); return }
        // a는 그대로다: 같은 실행, 같은 진행, 중지 표시 없음, 같은 자식이 살아 있고 결과도 없다.
        #expect(s.actives["a"] == before)
        #expect(c.childPID(envID: "a") == pidA && alive(pidA))
        #expect(s.results["a"] == nil && s.runIDs["a"] == nil)
        #expect(s.actives.keys.sorted() == ["a"])

        // 이번에는 a를 멈춘다. 그 사이 시작한 b는 중지 표시도 결과도 없이 계속 돈다.
        _ = c.start(envID: "b", pythonPath: fx.python.path, projectPath: fx.project.path)
        #expect(await waitUntil { c.snapshot.actives["b"]?.phase == .running(done: 0, total: 1) })
        let pidB = try #require(c.childPID(envID: "b"))
        c.stop(envID: "a")
        #expect(await waitUntil { c.snapshot.results["a"] != nil })
        s = c.snapshot
        guard case .incomplete(let ta, let stoppedA, _, _)? = s.results["a"] else { Issue.record("a: \(String(describing: s.results["a"]))"); return }
        #expect(ta == .signal(9) && stoppedA)
        #expect(s.actives["b"]?.stopping == false && s.actives["b"]?.phase == .running(done: 0, total: 1))
        #expect(c.childPID(envID: "b") == pidB && alive(pidB))
        #expect(s.results["b"] == nil)
        // 앞서 끝난 k·x 결과도 a 중지로 바뀌지 않았다.
        guard case .launchFailed? = s.results["x"] else { Issue.record("x가 바뀜"); return }
        c.stop(envID: "b")
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
    }

    /// 3. 한 실행이 끝나 오래된 파일을 정리할 때, 실행 중인 다른 실행들의 이벤트·로그 파일은 지우지 않는다.
    /// 실행 중인 hang 실행의 파일은 나중에 끝난 실행보다 오래돼서, 보호하지 않으면 keep=1에서 지워진다.
    @Test func cleanupProtectsEveryRunningRun() async throws {
        let fx = try Fixture(mode: "hang", aggregate: ControllerTests.aggJSON)
        try fx.setMode("ok", env: "c")
        try fx.paths.ensureDirectories()
        var old: [URL] = []
        for i in 0..<3 {
            let u = fx.paths.eventsDir.appendingPathComponent("\(uuid()).jsonl")
            try writeText("old", to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(i))], ofItemAtPath: u.path)
            old.append(u)
        }
        let c = fx.controller(grace: 0.3, keep: 1)
        guard case .started(let runA) = c.start(envID: "a", pythonPath: fx.python.path, projectPath: fx.project.path),
              case .started(let runB) = c.start(envID: "b", pythonPath: fx.python.path, projectPath: fx.project.path) else {
            Issue.record("시작하지 못함"); return
        }
        #expect(await waitUntil { c.snapshot.actives["a"]?.phase == .running(done: 0, total: 1)
                                  && c.snapshot.actives["b"]?.phase == .running(done: 0, total: 1) })
        // a·b 파일이 c보다 확실히 오래되게 한다(수정 시각 해상도 차이로 순서가 섞이지 않게).
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .started(let runC) = c.start(envID: "c", pythonPath: fx.python.path, projectPath: fx.project.path) else {
            Issue.record("c를 시작하지 못함"); return
        }
        #expect(await waitUntil { c.snapshot.results["c"] != nil })
        let fm = FileManager.default
        for run in [runA, runB, runC] {
            #expect(fm.fileExists(atPath: fx.paths.eventsFile(runID: run).path), "이벤트 파일이 지워짐: \(run)")
            #expect(fm.fileExists(atPath: fx.paths.logFile(runID: run).path), "로그 파일이 지워짐: \(run)")
        }
        for u in old { #expect(!fm.fileExists(atPath: u.path), "오래된 파일은 지워야 합니다") }
        // 지워진 파일 때문에 진행을 잃지 않았다(a·b는 여전히 0/1).
        #expect(c.snapshot.actives["a"]?.phase == .running(done: 0, total: 1))
        c.stopAll()
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
    }

    /// 3. 정리 함수 자체: 넘긴 실행 ID는 몇 개든 모두 남긴다.
    @Test func pruneAllProtectsEveryGivenRunID() throws {
        let paths = AppPaths(base: tempDir())
        try paths.ensureDirectories()
        var ids: [String] = []
        for i in 0..<5 {
            let id = uuid()
            ids.append(id)
            for u in [paths.eventsFile(runID: id), paths.logFile(runID: id)] {
                try writeText("x", to: u)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(i))], ofItemAtPath: u.path)
            }
        }
        // 가장 오래된 둘(ids[0], ids[1])을 보호하고 최신 1개만 남긴다.
        FileCleaner.pruneAll(paths, keep: 1, protecting: [ids[0], ids[1]])
        let fm = FileManager.default
        for (i, id) in ids.enumerated() {
            let expected = i == 0 || i == 1 || i == 4
            #expect(fm.fileExists(atPath: paths.eventsFile(runID: id).path) == expected)
            #expect(fm.fileExists(atPath: paths.logFile(runID: id).path) == expected)
        }
    }
}

/// 테스트 픽스처가 사라질 때 남은 가짜 pytest를 정리하는지 확인한다(테스트가 중간에 실패해도 자식이 남지 않게).
@Suite struct FixtureTeardownTests {
    @Test func leftoverChildIsKilledWhenFixtureGoesAway() async throws {
        var pid: pid_t = 0
        do {
            // 중지하지 않고 끝나는 테스트를 흉내 낸다. SIGINT를 무시하는 hang 자식을 남겨 둔다.
            let fx = try Fixture(mode: "hang")
            let c = fx.controller(grace: 60)
            _ = c.start(envID: "e", pythonPath: fx.python.path, projectPath: fx.project.path)
            #expect(await waitUntil { c.snapshot.actives["e"]?.phase == .running(done: 0, total: 1) })
            pid = try #require(c.childPID(envID: "e"))
        }
        // 블록을 벗어나 픽스처가 해제되면 deinit의 stopForTermination이 SIGKILL까지 보낸다.
        // 회수 전 좀비도 kill(pid, 0)이 성공하므로, ps로 그 pid가 살아 있는 fake-python인지 본다.
        #expect(await waitUntil(5) { !Self.isLiveFakePython(pid) })
    }

    /// pid가 살아 있는(좀비 아님) fake-python 프로세스인지 ps로 확인한다.
    private static func isLiveFakePython(_ pid: pid_t) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "stat=,command=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        ps.terminationHandler = { _ in done.signal() } // waitUntilExit는 쓰지 않는다(SystemProcessRunner 주석 참고)
        guard (try? ps.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        _ = done.wait(timeout: .now() + 3)
        return out.contains("fake-python") && !out.hasPrefix("Z")
    }
}

/// 7. 앱 종료 때 여러 자식을 하나의 마감 시각 안에 정리한다.
@Suite struct ConcurrentTerminationTests {
    /// SIGINT를 무시하는 자식 3개: 마감 0.5초를 함께 기다리고 한꺼번에 SIGKILL한다.
    /// 자식마다 따로 기다리면 1.5초 이상 걸린다.
    @Test func ignoringChildrenShareOneDeadline() async throws {
        let fx = try Fixture(mode: "hang")
        let c = fx.controller(grace: 60)
        let envs = ["a", "b", "c"]
        for env in envs { _ = c.start(envID: env, pythonPath: fx.python.path, projectPath: fx.project.path) }
        #expect(await waitUntil { envs.allSatisfy { c.snapshot.actives[$0]?.phase == .running(done: 0, total: 1) } })
        #expect(c.childPIDs.count == 3)
        let t0 = Date()
        #expect(c.stopForTermination(timeout: 0.5))
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed >= 0.4 && elapsed < 1.2, "걸린 시간 \(elapsed)")
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        for env in envs {
            guard case .incomplete(let t, _, _, _)? = c.snapshot.results[env] else {
                Issue.record("\(env): \(String(describing: c.snapshot.results[env]))"); continue
            }
            #expect(t == .signal(9))
        }
    }

    /// SIGINT로 끝나는 자식 3개: 모두에게 바로 신호가 가서 마감까지 가지 않고 돌아온다.
    @Test func sigintReachesEveryChildAtOnce() async throws {
        let fx = try Fixture(mode: "intexit")
        let c = fx.controller(grace: 60)
        let envs = ["a", "b", "c"]
        for env in envs { _ = c.start(envID: env, pythonPath: fx.python.path, projectPath: fx.project.path) }
        #expect(await waitUntil { envs.allSatisfy { c.snapshot.actives[$0]?.phase == .running(done: 0, total: 1) } })
        let t0 = Date()
        #expect(c.stopForTermination(timeout: 3))
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        for env in envs {
            guard case .incomplete(let t, _, _, _)? = c.snapshot.results[env] else {
                Issue.record("\(env): \(String(describing: c.snapshot.results[env]))"); continue
            }
            #expect(t == .exit(2)) // SIGKILL이 아니라 SIGINT 처리로 끝났다
        }
    }

    /// 종료는 대기 줄도 비운다. 실행 중인 것이 끝나도 대기하던 환경을 띄우지 않는다.
    @Test func terminationClearsQueueAndLaunchesNothing() async throws {
        let fx = try Fixture(mode: "hang", aggregate: ControllerTests.aggJSON)
        try fx.setMode("ok", env: "c")
        let c = fx.controller(grace: 60, limit: 2)
        let r = c.startAll(envs: ["a", "b", "c"].map { RunTarget(envID: $0, pythonPath: fx.python.path) },
                           projectPath: fx.project.path)
        #expect(r.queued == ["c"])
        #expect(await waitUntil { c.snapshot.actives["a"]?.phase == .running(done: 0, total: 1)
                                  && c.snapshot.actives["b"]?.phase == .running(done: 0, total: 1) })
        #expect(c.stopForTermination(timeout: 0.3))
        #expect(c.snapshot.actives["c"] == nil) // 반환 시점에 이미 대기 줄이 비었다
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(c.snapshot.actives.isEmpty && c.childPIDs.isEmpty)
        #expect(c.snapshot.results["c"] == nil)
    }
}

// MARK: 9단계 설계 5절 단위 5: 환경 B 결과가 환경 A 결과를 바꾸지 않음

@Suite struct EnvironmentIsolationTests {
    static let failedJSON = "{\"state\":\"completed\",\"verdict\":\"failed\",\"exit_code\":1,\"args\":[],\"counts\":{\"passed\":1,\"failed\":1},\"tests\":[{\"nodeid\":\"t.py::v\",\"status\":\"failed\"},{\"nodeid\":\"t.py::s\",\"status\":\"passed\"}]}"
    static let passedJSON = "{\"state\":\"completed\",\"verdict\":\"passed\",\"exit_code\":0,\"args\":[],\"counts\":{\"passed\":2},\"tests\":[{\"nodeid\":\"t.py::v\",\"status\":\"passed\"},{\"nodeid\":\"t.py::s\",\"status\":\"passed\"}]}"

    /// 실제 실행 경로(RunController): a는 실패, b는 통과하는 묶음을 돌린 뒤 b만 낱개로 다시 돌린다.
    /// a의 결과·실행 ID·끝난 시각·묶음 ID는 그대로이고(회복으로 바뀌지 않음), 비교 표는 환경 차이로만 보여 준다.
    @Test func otherEnvironmentRunNeverRewritesThisEnvironment() async throws {
        let fx = try Fixture(mode: "ok", aggregate: Self.failedJSON)
        let pythonB = try fx.python(named: "fake-python-b", aggregate: Self.passedJSON)
        let c = fx.controller()
        let r = c.startAll(envs: [RunTarget(envID: "a", pythonPath: fx.python.path),
                                  RunTarget(envID: "b", pythonPath: pythonB.path)], projectPath: fx.project.path)
        let batchID = try #require(r.batchID)
        #expect(await waitUntil { c.snapshot.actives.isEmpty })
        let first = c.snapshot
        guard case .finished(let sa)? = first.results["a"], case .finished(let sb)? = first.results["b"] else {
            Issue.record("결과: \(first.results)"); return
        }
        #expect(sa.verdict == "failed" && sb.verdict == "passed" && sa.args == [])
        #expect(first.batchIDs == ["a": batchID, "b": batchID] && first.batches[batchID]?.isFinished == true)

        // b를 낱개로 다시 돌려 통과. a의 키는 하나도 바뀌지 않는다.
        guard case .started(let rerun) = c.start(envID: "b", pythonPath: pythonB.path, projectPath: fx.project.path) else {
            Issue.record("b 다시 실행"); return
        }
        #expect(await waitUntil { c.snapshot.runIDs["b"] == rerun && c.snapshot.actives.isEmpty })
        let second = c.snapshot
        #expect(second.results["a"] == first.results["a"])
        #expect(second.runIDs["a"] == first.runIDs["a"] && second.finishedAt["a"] == first.finishedAt["a"])
        #expect(second.elapsed["a"] == first.elapsed["a"] && second.batchIDs["a"] == batchID)
        #expect(second.batchIDs["b"] == nil) // b는 낱개 결과라 묶음에서 빠진다
        // 묶음은 a의 결과가 아직 가리키므로 남는다(캐릭터·알림이 묶음 정보를 읽을 수 있게).
        #expect(second.batches[batchID] != nil)

        // 화면 값도 환경 키를 섞지 않는다: a 행은 여전히 실패, 비교는 "따로 실행"(묶음이 달라짐)과 a 실패·b 통과.
        let envA = PMHEnvironment(id: "a", name: "A", pythonPath: fx.python.path)
        let envB = PMHEnvironment(id: "b", name: "B", pythonPath: pythonB.path)
        let project = Project(path: fx.project.path, environments: [envA, envB])
        let ready = EnvCheck(status: .ready, report: nil, issues: [])
        #expect(ResultPresentation.row(env: envA, check: ready, snapshot: second, selected: false).statusText == "실패 1")
        let cmp = try #require(EnvComparison.build(project: project, checks: [:], snapshot: second, selectedEnvID: "a"))
        #expect(cmp.differingRows.map(\.id) == ["t.py::v#1"] && cmp.differingRows[0].cells == [.failed, .passed])
        #expect(cmp.relationText?.hasPrefix("따로 실행") == true)
    }
}

// MARK: 9단계 리뷰 결함 1·2: 대기 줄 꺼내기와 중지의 순서, 알림 순서

/// 알림으로 받은 상태를 모은다. notifyQueue(직렬)에서만 쓰고, 테스트는 notifyQueue.sync로 읽는다.
private final class SnapshotLog {
    var items: [RunSnapshot] = []
}

@Suite struct PromoteStopOrderTests {
    /// 결함 1: 대기 줄에서 꺼낸 직후(launch가 돌기 전) stop(envID:)가 끼어들어도 중지가 사라지지 않는다.
    /// 예전 코드는 꺼낸 실행의 launch를 잠금 밖·정리 뒤에 넣어서, 이 지점에서 부른 중지 작업이 launch보다 먼저 돌아
    /// "문맥 없음"으로 끝나고 pytest가 그대로 떴다(가짜 intexit는 60초 동안 돈다). 지금은 launch가 먼저 큐에 있어
    /// 중지가 바로 SIGINT를 보내고, b는 몇 초 안에 중단 결과로 끝난다. 묶음도 정상으로 끝남 판정을 받는다.
    @Test func stopRightAfterPromoteIsNotLost() async throws {
        let fx = try Fixture(mode: "ok", aggregate: ControllerTests.aggJSON)
        try fx.setMode("intexit", env: "b")
        let c = fx.controller(grace: 0.3, limit: 1)
        // 꺼낸 환경이 b면 그 자리에서 중지한다. 화면에서는 아직 "차례 기다림"으로 보이는 행의 ■나 [모두 중지]에 해당한다.
        // weak로 잡는 이유: 컨트롤러가 이 클로저를 쥐고 있어 강하게 잡으면 서로를 놓지 않는다.
        c.testHookAfterPromote = { [weak c] promoted in if promoted.contains("b") { c?.stop(envID: "b") } }
        let r = c.startAll(envs: ["a", "b"].map { RunTarget(envID: $0, pythonPath: fx.python.path) },
                           projectPath: fx.project.path)
        let batchID = try #require(r.batchID)
        #expect(r.started == ["a"] && r.queued == ["b"])
        // a는 0.6초쯤 뒤 끝나고 b가 꺼내지는 즉시 중지된다. 중지가 사라졌다면 b는 60초 동안 돌아 여기서 시간 초과로 실패한다.
        #expect(await waitUntil(8) { c.snapshot.actives.isEmpty })
        let s = c.snapshot
        #expect(c.childPIDs.isEmpty)
        // SIGINT가 셸의 trap 설치 전에 닿으면 이벤트 없이 시그널 2로 끝나고(수집 실패), 뒤에 닿으면 종료 기록 없는 중지(미완료 · 중지함)다.
        // 어느 쪽이든 끝까지 돌지 않았고 사용자가 멈춘 결과다.
        switch s.results["b"] {
        case .incomplete(_, let stopped, _, _)?: #expect(stopped)
        case .collectionFailed(let t, _)?: #expect(t == .signal(SIGINT))
        default: Issue.record("b 결과: \(String(describing: s.results["b"]))")
        }
        #expect((s.elapsed["b"] ?? 99) < 5)
        let batch = try #require(s.batches[batchID])
        #expect(batch.isFinished && batch.completedEnvIDs == ["a", "b"] && batch.cancelledEnvIDs.isEmpty)
    }

    /// 결함 2: 메인 쪽 publish(start)와 work 큐 publish(poll·complete)가 겹쳐도, 마지막으로 도착한 알림은 최종 상태다.
    /// 예전 코드는 상태 읽기와 notifyQueue에 넣기 사이에 틈이 있어, 먼저 읽은 옛 상태가 마지막에 도착할 수 있었다
    /// (끝난 환경이 "실행 중"으로 남음). 경쟁을 만들려고 여러 스레드에서 한꺼번에 start하고, 바로 끝나는 가짜 pytest를 쓴다.
    /// 경쟁은 확률적이라 예전 코드에서 늘 실패하지는 않지만, 고친 코드에서는 항상 통과해야 한다.
    @Test func lastDeliveredSnapshotIsTheFinalState() async throws {
        let fx = try Fixture(mode: "noevents")
        let notify = DispatchQueue(label: "test.order-notify")
        let log = SnapshotLog()
        let c = fx.controller(limit: 10, notifyQueue: notify, onChange: { log.items.append($0) })
        for round in 0..<4 {
            DispatchQueue.concurrentPerform(iterations: 16) { i in
                _ = c.start(envID: "r\(round)-e\(i)", pythonPath: fx.python.path, projectPath: fx.project.path)
            }
            #expect(await waitUntil { c.snapshot.actives.isEmpty })
        }
        // 마지막 complete의 알림은 정리(pruneAll) 뒤에 나가므로 잠시 늦게 올 수 있다. 최종 상태와 같아질 때까지 기다린다.
        #expect(await waitUntil(5) { notify.sync { log.items.last } == c.snapshot })
        // 그 뒤에 옛 상태가 늦게 도착해 덮어쓰지 않는지 조금 더 본다.
        try await Task.sleep(nanoseconds: 300_000_000)
        let last = notify.sync { log.items.last }
        #expect(last == c.snapshot)
        #expect(last?.actives.isEmpty == true)
    }
}
