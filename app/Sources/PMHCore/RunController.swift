// RunController.swift
// pytest 실행 1건을 시작·감시·중지하고 결과를 모으는 코드(앱 전체에서 동시에 1건만 허용).
// 입력: 환경 id, 선택한 python 경로, 프로젝트 폴더.
// 출력: 상태 변화 알림(RunSnapshot). 알림은 notifyQueue(앱에서는 메인 큐)로만 보낸다.
// 스레드: 프로세스 실행, 이벤트 파일 읽기, 집계 호출은 모두 내부 백그라운드 큐에서 한다.
//        메뉴가 응답하려면 메인 스레드에서 이 작업들을 기다리면 안 된다.

import Foundation

/// pytest 실행 1건을 관리한다. 앱 전체에서 동시에 1건만 허용한다.
/// 프로세스 실행·파일 읽기·집계 호출은 모두 이 클래스의 백그라운드 큐에서 하고,
/// 변경 알림만 `notifyQueue`(앱에서는 메인)로 보낸다.
public final class RunController {
    public static let pollInterval: TimeInterval = 0.25
    public static let stopGrace: TimeInterval = 5
    static let aggregateTimeout: TimeInterval = 30

    private let paths: AppPaths
    private let runner: ProcessRunning
    private let pollInterval: TimeInterval
    private let stopGrace: TimeInterval
    private let keep: Int
    private let notifyQueue: DispatchQueue
    private let onChange: (RunSnapshot) -> Void

    private let work = DispatchQueue(label: "pmh.run", qos: .userInitiated)
    private let lock = NSLock()
    private var state = RunSnapshot(active: nil, results: [:])
    private var context: Context?

    private final class Context {
        let runID: String
        let process = Process()
        var tail: EventTail
        var progress: RunProgress
        var timer: DispatchSourceTimer?
        var stopRequested = false
        var logHandle: FileHandle?
        init(runID: String, eventsFile: URL) {
            self.runID = runID
            tail = EventTail(url: eventsFile)
            progress = RunProgress(runID: runID)
        }
    }

    public init(paths: AppPaths = .default, runner: ProcessRunning = SystemProcessRunner(),
                pollInterval: TimeInterval = RunController.pollInterval,
                stopGrace: TimeInterval = RunController.stopGrace, keep: Int = FileCleaner.defaultKeep,
                notifyQueue: DispatchQueue = .main, onChange: @escaping (RunSnapshot) -> Void) {
        self.paths = paths; self.runner = runner; self.pollInterval = pollInterval
        self.stopGrace = stopGrace; self.keep = keep
        self.notifyQueue = notifyQueue; self.onChange = onChange
    }

    public var snapshot: RunSnapshot { lock.lock(); defer { lock.unlock() }; return state }

    /// 앱 시작 때 호출한다(백그라운드에서 실행).
    public func cleanup() {
        work.async { FileCleaner.pruneAll(self.paths, keep: self.keep) }
    }

    /// 시작을 요청한다. 이미 실행 중이면 거절한다. 나머지 작업은 백그라운드에서 한다.
    /// - Parameters:
    ///   - envID: 등록한 환경 id(자식 프로세스에 PMH_ENV_ID로 전달, 결과를 환경별로 보관).
    ///   - pythonPath: 사용자가 등록한 Python. 앱은 이 Python의 `-m pytest`만 실행한다.
    ///   - projectPath: 자식 프로세스의 작업 폴더.
    ///   - runID: 실행 ID(소문자 UUID). 기본은 새로 만든다. 플러그인이 같은 값을 이벤트 파일 이름에 쓴다.
    /// - Returns: 시작했으면 `.started`, 이미 실행 중이면 `.alreadyRunning`(아무것도 하지 않음).
    /// 확인과 "실행 중" 표시를 같은 잠금 안에서 하므로 두 번 연달아 눌러도 1건만 시작된다.
    public func start(envID: String, pythonPath: String, projectPath: String,
                      runID: String = UUID().uuidString.lowercased()) -> StartResult {
        lock.lock()
        if state.active != nil { lock.unlock(); return .alreadyRunning }
        state.active = ActiveRun(runID: runID, envID: envID, projectPath: projectPath,
                                 phase: .waitingForEvents, stopping: false)
        lock.unlock()
        publish()
        work.async { self.launch(runID: runID, envID: envID, pythonPath: pythonPath, projectPath: projectPath) }
        return .started(runID: runID)
    }

    /// 실행 중인 pytest를 멈춘다. 실행 중이 아니면 아무 일도 하지 않는다.
    /// SIGINT를 보내고 `stopGrace`초 안에 끝나지 않으면 강제 종료한다.
    public func stop() {
        work.async {
            guard let ctx = self.context, ctx.process.isRunning, !ctx.stopRequested else { return }
            ctx.stopRequested = true
            if self.mutate({ $0.active?.stopping = true }) { self.publish() }
            kill(ctx.process.processIdentifier, SIGINT)
            self.work.asyncAfter(deadline: .now() + self.stopGrace) {
                if ctx.process.isRunning { kill(ctx.process.processIdentifier, SIGKILL) }
            }
        }
    }

    // MARK: 내부(work 큐에서만)

    private func launch(runID: String, envID: String, pythonPath: String, projectPath: String) {
        let ctx = Context(runID: runID, eventsFile: paths.eventsFile(runID: runID))
        context = ctx
        do {
            try paths.ensureDirectories()
            let logURL = paths.logFile(runID: runID)
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]),
                  let log = FileHandle(forWritingAtPath: logURL.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            ctx.logHandle = log
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "프로젝트 폴더가 없습니다: \(projectPath)"])
            }
            let p = ctx.process
            p.executableURL = URL(fileURLWithPath: pythonPath)
            p.arguments = ["-m", "pytest"]
            p.currentDirectoryURL = URL(fileURLWithPath: projectPath)
            p.environment = Self.childEnvironment(envID: envID, runID: runID, eventsDir: paths.eventsDir)
            p.standardInput = FileHandle.nullDevice
            // 파이프가 아니라 파일로 보낸다. 읽는 쪽이 없어도 자식이 멈추지 않는다.
            p.standardOutput = log
            p.standardError = log
            p.terminationHandler = { [weak self] _ in self?.work.async { self?.finish(ctx, envID: envID, pythonPath: pythonPath) } }
            try p.run()
        } catch {
            try? ctx.logHandle?.close()
            context = nil
            complete(envID: envID, outcome: .launchFailed(message: "실행하지 못했습니다: \(error.localizedDescription)"), runID: runID)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll(ctx) }
        ctx.timer = timer
        timer.resume()
    }

    /// 사용자 환경 그대로 쓰되 플러그인을 끄는 변수는 지우고, 실행 ID·환경 ID·이벤트 폴더를 앱이 정한다.
    public static func childEnvironment(envID: String, runID: String, eventsDir: URL,
                                        base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env.removeValue(forKey: "PYTEST_DISABLE_PLUGIN_AUTOLOAD")
        env.removeValue(forKey: "PYTEST_MENU_DISABLE")
        env["PMH_ENV_ID"] = envID
        env["PMH_RUN_ID"] = runID
        env["PYTEST_MENU_EVENTS_DIR"] = eventsDir.path
        return env
    }

    /// 0.25초마다(그리고 종료 직후 1번) 이벤트 파일의 새 줄을 읽어 진행률을 갱신한다.
    /// 파일이 아직 없으면 실패가 아니라 "수집 대기"로 둔다(프로세스가 살아 있는 동안은 기다린다).
    private func poll(_ ctx: Context) {
        for line in ctx.tail.read() { ctx.progress.ingest(line) }
        let phase: RunPhase = ctx.progress.matchedEvents > 0
            ? .running(done: ctx.progress.done, total: ctx.progress.total)
            : (ctx.tail.fileSeen ? .running(done: 0, total: nil) : .waitingForEvents)
        if mutate({ if $0.active?.phase != phase { $0.active?.phase = phase } }) { publish() }
    }

    /// 프로세스가 끝난 뒤 결과를 확정한다. 순서가 중요하다:
    /// 1) 다른 run_id 이벤트가 섞였으면 오류, 2) 이벤트가 하나도 없으면 수집 실패,
    /// 3) 종료 이벤트가 없으면 미완료, 4) 그 외에는 집계기에 판정을 맡긴다.
    /// 종료 이벤트 없는 실행을 집계기에 넘기지 않는 이유: 강제 종료로 마지막 줄이 잘렸을 수 있어 집계가 오류를 낼 수 있다.
    private func finish(_ ctx: Context, envID: String, pythonPath: String) {
        ctx.timer?.cancel()
        ctx.timer = nil
        poll(ctx) // 종료 직전에 쓰인 마지막 이벤트까지 읽는다.
        try? ctx.logHandle?.close()
        let p = ctx.process
        let termination: Termination = p.terminationReason == .uncaughtSignal
            ? .signal(p.terminationStatus) : .exit(p.terminationStatus)
        let progress = ctx.progress
        let outcome: RunOutcome
        if progress.foreignEvents > 0 {
            outcome = .eventsMixed(foreign: progress.foreignEvents)
        } else if progress.matchedEvents == 0 {
            outcome = .collectionFailed(termination: termination, logTail: Self.lastLogLine(paths.logFile(runID: ctx.runID)))
        } else if !progress.sawFinish {
            outcome = .incomplete(termination: termination, stopped: ctx.stopRequested,
                                  done: progress.done, total: progress.total)
        } else {
            outcome = aggregate(pythonPath: pythonPath, runID: ctx.runID)
        }
        context = nil
        complete(envID: envID, outcome: outcome, runID: ctx.runID)
    }

    /// 판정은 Python 집계기를 1번 호출해 받는다. 실패는 판정이 아니라 오류로 돌려준다.
    private func aggregate(pythonPath: String, runID: String) -> RunOutcome {
        let out = runner.run(executable: pythonPath,
                             arguments: ["-I", "-m", "pytest_menu_helper.aggregate", paths.eventsFile(runID: runID).path],
                             workingDirectory: "/", timeout: Self.aggregateTimeout)
        if out.timedOut { return .aggregationFailed(message: "집계가 \(Int(Self.aggregateTimeout))초 안에 끝나지 않았습니다.") }
        if out.exitCode != 0 {
            let tail = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            return .aggregationFailed(message: "집계 호출에 실패했습니다(종료 코드 \(out.exitCode)). 플러그인이 오래됐을 수 있습니다. \(tail)")
        }
        guard let summary = try? JSONDecoder().decode(RunSummary.self, from: out.stdout) else {
            return .aggregationFailed(message: "집계 결과를 해석하지 못했습니다.")
        }
        if let id = summary.runID, id != runID { return .eventsMixed(foreign: 1) }
        return .finished(summary)
    }

    /// 결과를 저장하고 실행 중 표시를 지운 뒤, 오래된 파일을 정리하고 알린다.
    private func complete(envID: String, outcome: RunOutcome, runID: String) {
        lock.lock()
        state.results[envID] = outcome
        state.active = nil
        lock.unlock()
        FileCleaner.pruneAll(paths, keep: keep, protectingRunID: runID)
        publish()
    }

    @discardableResult
    private func mutate(_ change: (inout RunSnapshot) -> Void) -> Bool {
        lock.lock()
        let before = state
        change(&state)
        let changed = before != state
        lock.unlock()
        return changed
    }

    private func publish() {
        let snap = snapshot
        notifyQueue.async { self.onChange(snap) }
    }

    static func lastLogLine(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self) // 읽기 경계에서 잘린 바이트는 대체 문자로 바뀐다
        guard let line = text.split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let s = line.trimmingCharacters(in: .whitespaces)
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }
}
