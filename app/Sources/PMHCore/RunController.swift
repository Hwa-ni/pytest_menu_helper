// RunController.swift
// pytest 실행 1건을 시작·감시·중지하고 결과를 모으는 코드(앱 전체에서 동시에 1건만 허용).
// 입력: 환경 id, 선택한 python 경로, 프로젝트 폴더.
// 출력: 상태 변화 알림(RunSnapshot). 알림은 notifyQueue(앱에서는 메인 큐)로만 보낸다.
// 스레드: 프로세스 실행, 이벤트 파일 읽기, 집계 호출은 모두 내부 백그라운드 큐에서 한다.
//        메뉴가 응답하려면 메인 스레드에서 이 작업들을 기다리면 안 된다.
//        예외는 앱 종료 때의 stopForTermination 하나뿐이다. 이 함수는 work 큐를 기다리지 않고
//        잠금으로 보호한 자식 프로세스 참조만 써서, 정해진 상한 안에서 메인 스레드를 돌려준다.

import Foundation

/// pytest 실행 1건을 관리한다. 앱 전체에서 동시에 1건만 허용한다.
/// 프로세스 실행·파일 읽기·집계 호출은 모두 이 클래스의 백그라운드 큐에서 하고,
/// 변경 알림만 `notifyQueue`(앱에서는 메인)로 보낸다.
public final class RunController {
    public static let pollInterval: TimeInterval = 0.25
    public static let stopGrace: TimeInterval = 5
    static let aggregateTimeout: TimeInterval = Aggregation.timeout

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
    /// 지금 살아 있을 수 있는 pytest 자식 프로세스. `lock`으로 보호한다.
    /// work 큐 전용인 `context`와 따로 두는 이유: 앱 종료 때 메인 스레드가 work 큐를 기다리지 않고
    /// 바로 신호를 보낼 수 있어야 한다. work 큐는 집계 호출(최대 30초) 중일 수 있어 work.sync를 쓰면
    /// 종료가 그만큼 멈춘다.
    private var runningProcess: Process?
    /// 앱 종료가 시작됐는지. `lock`으로 보호한다. 켜진 뒤에는 새 자식 프로세스를 띄우지 않는다.
    /// 빠뜨리면 start 직후 종료할 때, 종료 처리가 끝난 다음에 work 큐가 pytest를 띄워 앱보다 오래 남을 수 있다.
    private var terminating = false
    /// 이 앱이 시작한 실행 ID 전체(끝난 것 포함). `lock`으로 보호한다.
    /// 외부 실행 감시기가 이 집합에 있는 파일을 외부 실행으로 세지 않게 해, 앱 실행이 두 번 보이지 않게 한다.
    /// 끝난 뒤에도 지우지 않는 이유: 파일은 폴더에 남아 있고, 감시기가 나중에 처음 볼 수도 있다.
    private var appRunIDs: Set<String> = []

    private final class Context {
        let runID: String
        let process = Process()
        var tail: EventTail
        var progress: RunProgress
        var timer: DispatchSourceTimer?
        var stopRequested = false
        var logHandle: FileHandle?
        /// pytest 프로세스를 띄운 시각. 소요 시간 계산에 쓴다. 띄우기 전에는 nil이다.
        var launchedAt: Date?
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
        // 파일이 생기기 전에 등록해야 감시기가 이 실행을 외부 실행으로 오인하지 않는다.
        appRunIDs.insert(runID)
        state.active = ActiveRun(runID: runID, envID: envID, projectPath: projectPath,
                                 phase: .waitingForEvents, stopping: false, startedAt: Date())
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

    /// 앱 종료 전용 동기 중지. 반환하기 전에 SIGINT를 실제로 보내고, 자식이 끝나기를 잠시 기다린다.
    /// 그래도 살아 있으면 SIGKILL로 끝낸다. 일반 `stop()`은 work 큐에 넘기기만 해서, 앱이 바로 끝나면
    /// 신호가 나가기 전에 프로세스가 사라질 수 있다. 이 함수는 그 문제를 막는다.
    ///
    /// 메인 스레드에서 불러도 안전하다. work 큐를 기다리지 않고(`work.sync` 없음) 잠금으로 보호한
    /// `runningProcess`만 읽으므로, work 큐가 집계 중이어도 막히지 않고 데드락 경로도 없다.
    /// 잠금은 짧게(값 읽기·쓰기만) 잡고, 기다리는 동안에는 잠금을 쥐지 않는다.
    ///
    /// - Parameter timeout: SIGINT 뒤 자식 종료를 기다릴 최대 시간(초). 메인 스레드를 오래 막지 않도록
    ///   `maxTerminationWait`(5초)를 넘기면 그 값으로 줄이고, 음수는 0으로 본다.
    ///   SIGKILL 뒤에는 이와 별도로 최대 `killWait`(0.5초)만 더 기다린다. 따라서 전체 상한은 약 5.5초다.
    /// - Returns: 반환 시점에 자식이 없거나 끝났으면 true. SIGKILL 뒤에도 끝난 것을 확인하지 못했으면 false.
    ///   실패해도 예외를 던지지 않는다(앱은 어차피 종료 중이라 할 수 있는 일이 없다).
    /// 이 함수를 부른 뒤에는 새 실행이 시작되지 않는다(launch가 `terminating`을 보고 거절한다).
    @discardableResult
    public func stopForTermination(timeout: TimeInterval = RunController.terminationWait) -> Bool {
        lock.lock()
        terminating = true
        let process = runningProcess
        lock.unlock()
        // 실행 중이 아니거나 이미 끝난 프로세스면 보낼 신호가 없다.
        guard let process = process, process.isRunning else { return true }
        let pid = process.processIdentifier
        kill(pid, SIGINT)
        let wait = min(max(timeout, 0), Self.maxTerminationWait)
        if Self.waitForExit(process, seconds: wait) { return true }
        // isRunning을 다시 확인한 뒤 보낸다. 이미 끝나 회수된 pid는 다른 프로세스가 재사용할 수 있어서다.
        if process.isRunning { kill(pid, SIGKILL) }
        return Self.waitForExit(process, seconds: Self.killWait)
    }

    /// 앱 종료 때 SIGINT 뒤 기다리는 기본 시간(초). pytest가 중단 이벤트를 남기고 끝나기에 보통 충분하다.
    public static let terminationWait: TimeInterval = 2.5
    /// stopForTermination이 SIGINT 뒤 기다릴 수 있는 최대 시간(초). 메인 스레드를 오래 막지 않기 위한 상한이다.
    public static let maxTerminationWait: TimeInterval = 5
    /// SIGKILL 뒤 종료 확인을 기다리는 시간(초). SIGKILL은 막을 수 없어 보통 수 밀리초 안에 끝난다.
    static let killWait: TimeInterval = 0.5

    /// 프로세스가 끝날 때까지 짧은 간격(20ms)으로 확인하며 최대 `seconds`초 기다린다.
    /// 런루프나 work 큐에 기대지 않는 바쁜 대기 대신 sleep을 쓰는 이유: 메인 스레드에서 불려도
    /// 다른 큐의 도움 없이 끝나야 하기 때문이다. Process.isRunning은 Foundation 내부 큐가 갱신한다.
    /// - Returns: 기다리는 안에 끝났으면 true, 시간이 다 되도록 살아 있으면 false.
    private static func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= end { return false }
            usleep(20_000)
        }
        return true
    }

    /// 이 앱이 시작한 실행 ID인지. 외부 실행 감시기가 부른다(어느 스레드에서든 안전).
    public func isAppRun(_ runID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return appRunIDs.contains(runID)
    }

    /// 테스트용: 지금 등록된 자식 프로세스의 pid(없으면 nil).
    var childPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return runningProcess?.processIdentifier
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
            // 종료 여부 확인, 프로세스 시작, 참조 등록을 한 잠금 안에서 한다.
            // 따로 하면 그 사이에 stopForTermination이 끼어들어, 아직 등록 전인 자식을 놓친 채
            // 앱이 끝날 수 있다. p.run()은 생성만 하고 바로 돌아오므로 잠금을 오래 쥐지 않는다.
            lock.lock()
            if terminating {
                lock.unlock()
                throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "앱이 종료되는 중입니다."])
            }
            do { try p.run() } catch { lock.unlock(); throw error }
            ctx.launchedAt = Date()
            runningProcess = p
            lock.unlock()
        } catch {
            try? ctx.logHandle?.close()
            context = nil
            complete(envID: envID, outcome: .launchFailed(message: "실행하지 못했습니다: \(error.localizedDescription)"),
                     runID: runID, elapsed: nil)
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
        // 끝난 프로세스는 더 이상 신호 대상이 아니다. 같은 객체일 때만 지운다(다른 실행의 참조를 지우지 않도록).
        lock.lock()
        if runningProcess === ctx.process { runningProcess = nil }
        lock.unlock()
        // 소요 시간은 집계 호출 전에 잰다. 집계(최대 30초)는 pytest 실행 시간이 아니기 때문이다.
        let elapsed = ctx.launchedAt.map { Date().timeIntervalSince($0) }
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
        complete(envID: envID, outcome: outcome, runID: ctx.runID, elapsed: elapsed)
    }

    /// 판정은 Python 집계기를 1번 호출해 받는다. 외부 실행 감시기와 같은 함수(Aggregation.run)를 쓴다.
    private func aggregate(pythonPath: String, runID: String) -> RunOutcome {
        Aggregation.run(runner: runner, pythonPath: pythonPath, eventsFile: paths.eventsFile(runID: runID), runID: runID)
    }

    /// 결과를 저장하고 실행 중 표시를 지운 뒤, 오래된 파일을 정리하고 알린다.
    /// 매개변수 elapsed: pytest 프로세스의 실행 시간(초). 시작하지 못했으면 nil이고, 이때는 이전 값도 지운다
    /// (지우지 않으면 새 결과 옆에 지난 실행의 시간이 보인다).
    private func complete(envID: String, outcome: RunOutcome, runID: String, elapsed: TimeInterval?) {
        lock.lock()
        state.results[envID] = outcome
        // 결과를 낸 실행 ID. 완료 알림이 같은 실행을 한 번만 보내는 기준이다(8단계).
        state.runIDs[envID] = runID
        state.elapsed[envID] = elapsed
        // 외부 실행 결과와 최신을 비교할 시각(RunSnapshot.merged).
        state.finishedAt[envID] = Date()
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
