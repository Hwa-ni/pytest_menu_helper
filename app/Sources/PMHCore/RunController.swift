// RunController.swift
// pytest 실행을 시작·감시·중지하고 결과를 모으는 코드.
// 9단계부터 여러 환경을 동시에 실행한다. 한 환경에는 동시에 1건만, 앱 전체로는 maxConcurrentRuns(10)개까지.
// [모두 실행](startAll)에서 제한을 넘는 환경은 차례 대기 줄에 넣었다가 자리가 나면 자동으로 시작한다.
// 입력: 환경 id, 선택한 python 경로, 프로젝트 폴더(낱개 start 또는 묶음 startAll).
// 출력: 상태 변화 알림(RunSnapshot). 알림은 notifyQueue(앱에서는 메인 큐)로만 보낸다.
// 스레드: 프로세스 실행, 이벤트 파일 읽기, 집계 호출은 모두 내부 백그라운드 큐(work 큐 하나)에서 한다.
//        work 큐 하나가 여러 실행의 타이머를 돌린다. 각 작업이 짧아 충분하지만, 한 실행의 집계 호출(최대 30초)
//        동안 다른 실행의 진행 갱신이 멈출 수 있다(설계 6절 위험. 측정에서 눈에 띄면 집계를 별도 큐로 옮긴다).
//        메뉴가 응답하려면 메인 스레드에서 이 작업들을 기다리면 안 된다.
//        예외는 앱 종료 때의 stopForTermination 하나뿐이다. 이 함수는 work 큐를 기다리지 않고
//        잠금으로 보호한 자식 프로세스 참조만 써서, 정해진 상한 안에서 메인 스레드를 돌려준다.

import Foundation

/// pytest 실행을 관리한다. 한 환경에는 동시에 1건, 앱 전체로는 `maxConcurrentRuns`개까지 허용한다.
/// 프로세스 실행·파일 읽기·집계 호출은 모두 이 클래스의 백그라운드 큐에서 하고,
/// 변경 알림만 `notifyQueue`(앱에서는 메인)로 보낸다.
public final class RunController {
    public static let pollInterval: TimeInterval = 0.25
    public static let stopGrace: TimeInterval = 5
    /// 앱이 동시에 띄울 수 있는 pytest 수의 기본값. 이 Mac의 코어 수(10)와 같다(7절 결정 2, 2026-11-17).
    /// 터미널에서 띄운 실행은 앱이 띄우지 않았으므로 세지 않는다.
    public static let maxConcurrentRuns = 10
    static let aggregateTimeout: TimeInterval = Aggregation.timeout

    private let paths: AppPaths
    private let runner: ProcessRunning
    private let pollInterval: TimeInterval
    private let stopGrace: TimeInterval
    private let keep: Int
    /// 이 컨트롤러의 동시 실행 상한. 기본은 maxConcurrentRuns이고 테스트에서 줄여 대기 줄을 확인한다.
    private let runLimit: Int
    private let notifyQueue: DispatchQueue
    private let onChange: (RunSnapshot) -> Void

    private let work = DispatchQueue(label: "pmh.run", qos: .userInitiated)
    private let lock = NSLock()
    /// 실행 상태 전체. `lock`으로 보호한다.
    private var state = RunSnapshot()
    /// 실행 ID → 실행 문맥. work 큐에서만 읽고 쓴다(잠금 없음).
    private var contexts: [String: Context] = [:]
    /// 실행 ID → 지금 살아 있을 수 있는 pytest 자식 프로세스. `lock`으로 보호한다.
    /// work 큐 전용인 `contexts`와 따로 두는 이유: 앱 종료 때 메인 스레드가 work 큐를 기다리지 않고
    /// 바로 신호를 보낼 수 있어야 한다. work 큐는 집계 호출(최대 30초) 중일 수 있어 work.sync를 쓰면
    /// 종료가 그만큼 멈춘다.
    private var runningProcesses: [String: Process] = [:]
    /// 차례를 기다리는 실행(먼저 넣은 것이 앞). `lock`으로 보호한다. 각 항목은 state.actives에 .queued로도 들어 있다.
    private var pending: [PendingRun] = []
    /// 앱 종료가 시작됐는지. `lock`으로 보호한다. 켜진 뒤에는 새 자식 프로세스를 띄우지 않고 대기 줄도 풀지 않는다.
    /// 빠뜨리면 start 직후 종료할 때, 종료 처리가 끝난 다음에 work 큐가 pytest를 띄워 앱보다 오래 남을 수 있다.
    private var terminating = false
    /// 이 앱이 시작한 실행 ID 전체(끝난 것 포함). `lock`으로 보호한다.
    /// 외부 실행 감시기가 이 집합에 있는 파일을 외부 실행으로 세지 않게 해, 앱 실행이 두 번 보이지 않게 한다.
    /// 끝난 뒤에도 지우지 않는 이유: 파일은 폴더에 남아 있고, 감시기가 나중에 처음 볼 수도 있다.
    private var appRunIDs: Set<String> = []

    /// 띄우기 전 실행 요청 1건. 바로 시작할 때와 대기 줄에서 꺼낼 때 같은 값을 launch에 넘긴다.
    private struct PendingRun {
        let runID: String
        let envID: String
        let pythonPath: String
        let projectPath: String
        let batchID: String?
    }

    /// 띄운 실행 1건의 문맥. work 큐에서만 쓴다.
    private final class Context {
        let runID: String
        let envID: String
        let batchID: String?
        let process = Process()
        var tail: EventTail
        var progress: RunProgress
        var timer: DispatchSourceTimer?
        var stopRequested = false
        var logHandle: FileHandle?
        /// pytest 프로세스를 띄운 시각. 소요 시간 계산에 쓴다. 띄우기 전에는 nil이다.
        var launchedAt: Date?
        init(runID: String, envID: String, batchID: String?, eventsFile: URL) {
            self.runID = runID; self.envID = envID; self.batchID = batchID
            tail = EventTail(url: eventsFile)
            progress = RunProgress(runID: runID)
        }
    }

    /// - Parameters:
    ///   - paths: 이벤트·로그 폴더.
    ///   - runner: 집계 호출에 쓸 프로세스 실행기(테스트에서 바꾼다).
    ///   - pollInterval: 이벤트 파일을 읽는 주기(초).
    ///   - stopGrace: 낱개 중지에서 SIGINT 뒤 SIGKILL까지 기다리는 시간(초).
    ///   - keep: 정리 때 남길 최신 파일 수.
    ///   - maxConcurrentRuns: 동시 실행 상한. 1보다 작으면 1로 본다(0이면 아무것도 시작할 수 없어 대기 줄이 영원히 남는다).
    ///   - notifyQueue·onChange: 상태 변화 알림을 받을 큐와 함수.
    public init(paths: AppPaths = .default, runner: ProcessRunning = SystemProcessRunner(),
                pollInterval: TimeInterval = RunController.pollInterval,
                stopGrace: TimeInterval = RunController.stopGrace, keep: Int = FileCleaner.defaultKeep,
                maxConcurrentRuns: Int = RunController.maxConcurrentRuns,
                notifyQueue: DispatchQueue = .main, onChange: @escaping (RunSnapshot) -> Void) {
        self.paths = paths; self.runner = runner; self.pollInterval = pollInterval
        self.stopGrace = stopGrace; self.keep = keep
        self.runLimit = max(1, maxConcurrentRuns)
        self.notifyQueue = notifyQueue; self.onChange = onChange
        state.runLimit = runLimit
    }

    public var snapshot: RunSnapshot { lock.lock(); defer { lock.unlock() }; return state }

    /// 앱 시작 때 호출한다(백그라운드에서 실행).
    /// 정리 직전에 실행 중인 ID를 다시 읽어 보호한다. 앱 시작 직후 사용자가 바로 ▶를 누를 수 있어서다.
    public func cleanup() {
        work.async { FileCleaner.pruneAll(self.paths, keep: self.keep, protecting: self.protectedRunIDs()) }
    }

    /// 한 환경의 실행 시작을 요청한다. 나머지 작업은 백그라운드에서 한다.
    /// - Parameters:
    ///   - envID: 등록한 환경 id(자식 프로세스에 PMH_ENV_ID로 전달, 결과를 환경별로 보관).
    ///   - pythonPath: 사용자가 등록한 Python. 앱은 이 Python의 `-m pytest`만 실행한다.
    ///   - projectPath: 자식 프로세스의 작업 폴더.
    ///   - runID: 실행 ID(소문자 UUID). 기본은 새로 만든다. 플러그인이 같은 값을 이벤트 파일 이름에 쓴다.
    /// - Returns: 시작했으면 `.started`, 이 환경이 이미 실행 중·대기 중이면 `.alreadyRunning`,
    ///   동시 실행 수가 다 찼으면 `.limitReached`. 거절하면 아무것도 바꾸지 않는다.
    /// 확인과 "실행 중" 표시를 같은 잠금 안에서 하므로 두 번 연달아 눌러도 1건만 시작된다.
    /// 낱개 ▶는 대기 줄에 넣지 않는다(7절 결정 2). 누른 순간 시작하지 않는 실행은 사용자가 예상하지 못한다.
    public func start(envID: String, pythonPath: String, projectPath: String,
                      runID: String = UUID().uuidString.lowercased()) -> StartResult {
        lock.lock()
        if state.actives[envID] != nil { lock.unlock(); return .alreadyRunning }
        if state.runningCount >= runLimit { lock.unlock(); return .limitReached }
        // 파일이 생기기 전에 등록해야 감시기가 이 실행을 외부 실행으로 오인하지 않는다.
        appRunIDs.insert(runID)
        state.actives[envID] = ActiveRun(runID: runID, envID: envID, projectPath: projectPath,
                                         phase: .waitingForEvents, stopping: false, startedAt: Date())
        let request = PendingRun(runID: runID, envID: envID, pythonPath: pythonPath, projectPath: projectPath, batchID: nil)
        // launch를 "실행 중" 표시와 같은 잠금 안에서 work 큐에 넣는다(launchOrderRule 참고).
        // work.async는 넣기만 하고 바로 돌려주므로 잠금을 쥔 채 불러도 기다림이나 교착이 없다.
        work.async { self.launch(request) }
        lock.unlock()
        publish()
        return .started(runID: runID)
    }

    /// [모두 실행]. 묶음 ID를 하나 만들고 환경마다 시작한다.
    /// - Parameters:
    ///   - envs: 실행할 환경(순서대로 시작한다). 실행 가능 여부(검사 통과, 플러그인 있음)는 부르는 쪽이 미리 거른다.
    ///   - projectPath: 모든 환경이 함께 쓸 프로젝트 폴더.
    ///   - batchID: 묶음 ID. 기본은 새 UUID(소문자).
    /// - Returns: 묶음 ID와 환경별 처리(바로 시작, 대기 줄, 이미 실행 중이라 뺌).
    ///   시작하거나 대기 줄에 넣은 환경이 없으면 묶음을 만들지 않고 batchID가 nil이다.
    /// 동시 실행 수를 넘는 환경은 .queued로 actives에 넣고 대기 줄에 둔다. 앞 실행이 끝나면 complete가 꺼내 시작한다.
    /// 같은 환경 id가 목록에 두 번 있으면 두 번째는 alreadyRunning으로 빠진다(한 환경에 동시에 1건 규칙).
    @discardableResult
    public func startAll(envs: [RunTarget], projectPath: String,
                         batchID: String = UUID().uuidString.lowercased()) -> BatchStartResult {
        var result = BatchStartResult(batchID: nil, started: [], queued: [], alreadyRunning: [], runIDs: [:])
        var toLaunch: [PendingRun] = []
        lock.lock()
        for target in envs {
            if state.actives[target.envID] != nil { result.alreadyRunning.append(target.envID); continue }
            let runID = UUID().uuidString.lowercased()
            appRunIDs.insert(runID)
            result.runIDs[target.envID] = runID
            let request = PendingRun(runID: runID, envID: target.envID, pythonPath: target.pythonPath,
                                     projectPath: projectPath, batchID: batchID)
            // runningCount는 이 반복에서 방금 넣은 실행도 센다(actives에 바로 넣기 때문이다).
            let canRun = state.runningCount < runLimit
            state.actives[target.envID] = ActiveRun(runID: runID, envID: target.envID, projectPath: projectPath,
                                                    phase: canRun ? .waitingForEvents : .queued, stopping: false,
                                                    startedAt: Date(), batchID: batchID)
            if canRun {
                toLaunch.append(request)
                result.started.append(target.envID)
            } else {
                pending.append(request)
                result.queued.append(target.envID)
            }
        }
        let members = result.started + result.queued
        if !members.isEmpty {
            result.batchID = batchID
            state.batches[batchID] = BatchState(envIDs: members, runIDs: result.runIDs,
                                                projectPath: projectPath, startedAt: Date())
        }
        // 바로 시작할 실행의 launch를 잠금 안에서 넣는다(launchOrderRule). 잠금을 푼 뒤에 넣으면, 그 틈에 다른 스레드의
        // stop(envID:)가 중지 작업을 launch보다 먼저 work 큐에 넣어 중지가 사라질 수 있다.
        for request in toLaunch { work.async { self.launch(request) } }
        lock.unlock()
        if !members.isEmpty { publish() }
        return result
    }

    /// 한 환경의 실행을 멈춘다. 그 환경에 실행이 없으면 아무 일도 하지 않는다. 다른 환경은 건드리지 않는다.
    /// - Parameter envID: 멈출 환경 id.
    /// 차례를 기다리는 중이면 대기만 취소한다(프로세스가 없다). 결과는 바뀌지 않고, 묶음에는 "취소함"으로 남는다.
    /// 실행 중이면 SIGINT를 보내고 `stopGrace`초 안에 끝나지 않으면 강제 종료한다.
    public func stop(envID: String) {
        lock.lock()
        guard let active = state.actives[envID] else { lock.unlock(); return }
        if active.isQueued {
            cancelQueuedLocked(active)
            lock.unlock()
            publish()
            return
        }
        lock.unlock()
        let runID = active.runID
        work.async {
            // 문맥이 없으면 이미 끝났거나 시작하지 못한 실행이다. 띄우기 전이라 문맥이 없는 경우는 없다:
            // 위에서 본 "차례 기다림이 아님"(실행 중 표시)은 launch를 work 큐에 넣은 바로 그 잠금 구간에서만 생긴다
            // (launchOrderRule). 그래서 이 중지 작업은 언제나 그 launch보다 뒤에 큐에 들어가, launch가 먼저 돈다.
            guard let ctx = self.contexts[runID], ctx.process.isRunning, !ctx.stopRequested else { return }
            ctx.stopRequested = true
            // 실행 ID가 같을 때만 표시한다. 그 사이 끝나고 같은 환경에 새 실행이 들어왔으면 새 실행을 건드리면 안 된다.
            if self.mutate({ s in if s.actives[envID]?.runID == runID { s.actives[envID]?.stopping = true } }) {
                self.publish()
            }
            kill(ctx.process.processIdentifier, SIGINT)
            self.work.asyncAfter(deadline: .now() + self.stopGrace) {
                if ctx.process.isRunning { kill(ctx.process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// [모두 중지]. 대기 줄을 먼저 모두 취소한 뒤, 실행 중인 모든 환경에 stop(envID:)과 같은 절차를 한다.
    /// 대기 줄을 먼저 비우는 이유: 실행 중인 것을 먼저 멈추면, 그 실행이 끝날 때 대기 줄에서 다음 환경이 시작된다.
    public func stopAll() {
        lock.lock()
        let queued = pending.compactMap { state.actives[$0.envID] }.filter { $0.isQueued }
        for active in queued { cancelQueuedLocked(active) }
        let running = state.actives.values.filter { !$0.isQueued }.map(\.envID)
        lock.unlock()
        if !queued.isEmpty { publish() }
        for envID in running { stop(envID: envID) }
    }

    /// 대기 중인 실행 하나를 취소한다. `lock`을 쥔 채로 불러야 한다.
    /// actives와 대기 줄에서 빼고, 묶음에 "취소함"으로 적는다. 실행 ID는 appRunIDs에 남는다(파일이 없으니 해가 없다).
    private func cancelQueuedLocked(_ active: ActiveRun) {
        pending.removeAll { $0.runID == active.runID }
        state.actives[active.envID] = nil
        if let batchID = active.batchID { markBatchLocked(batchID, envID: active.envID, cancelled: true) }
        pruneBatchesLocked()
    }

    /// 앱 종료 전용 동기 중지. 반환하기 전에 살아 있는 모든 자식에 SIGINT를 실제로 보내고, 끝나기를 잠시 기다린다.
    /// 그래도 살아 있는 것은 SIGKILL로 끝낸다. 일반 `stop(envID:)`은 work 큐에 넘기기만 해서, 앱이 바로 끝나면
    /// 신호가 나가기 전에 프로세스가 사라질 수 있다. 이 함수는 그 문제를 막는다. 대기 줄도 비운다.
    ///
    /// 여러 자식은 하나의 마감 시각까지 함께 기다린다. 자식마다 따로 기다리면 3개일 때 종료가 최대 16초 멈춘다.
    ///
    /// 메인 스레드에서 불러도 안전하다. work 큐를 기다리지 않고(`work.sync` 없음) 잠금으로 보호한
    /// `runningProcesses`만 읽으므로, work 큐가 집계 중이어도 막히지 않고 데드락 경로도 없다.
    /// 잠금은 짧게(값 읽기·쓰기만) 잡고, 기다리는 동안에는 잠금을 쥐지 않는다.
    ///
    /// - Parameter timeout: SIGINT 뒤 모든 자식의 종료를 기다릴 최대 시간(초). 메인 스레드를 오래 막지 않도록
    ///   `maxTerminationWait`(5초)를 넘기면 그 값으로 줄이고, 음수는 0으로 본다.
    ///   SIGKILL 뒤에는 이와 별도로 최대 `killWait`(0.5초)만 더 기다린다. 따라서 자식 수와 상관없이 전체 상한은 약 5.5초다.
    /// - Returns: 반환 시점에 자식이 없거나 모두 끝났으면 true. SIGKILL 뒤에도 하나라도 끝난 것을 확인하지 못했으면 false.
    ///   실패해도 예외를 던지지 않는다(앱은 어차피 종료 중이라 할 수 있는 일이 없다).
    /// 이 함수를 부른 뒤에는 새 실행이 시작되지 않는다(launch가 `terminating`을 보고 거절하고, 대기 줄을 풀지 않는다).
    @discardableResult
    public func stopForTermination(timeout: TimeInterval = RunController.terminationWait) -> Bool {
        lock.lock()
        terminating = true
        // 대기 줄을 비운다. 결과는 남기지 않는다(실행하지 않았고 앱이 곧 끝난다).
        let hadQueue = !pending.isEmpty
        for request in pending where state.actives[request.envID]?.runID == request.runID {
            state.actives[request.envID] = nil
        }
        pending.removeAll()
        let processes = Array(runningProcesses.values)
        lock.unlock()
        if hadQueue { publish() }
        // 실행 중이 아니거나 이미 끝난 프로세스에는 보낼 신호가 없다.
        let alive = processes.filter { $0.isRunning }
        guard !alive.isEmpty else { return true }
        for process in alive { kill(process.processIdentifier, SIGINT) }
        let wait = min(max(timeout, 0), Self.maxTerminationWait)
        if Self.waitForExit(alive, until: Date().addingTimeInterval(wait)) { return true }
        // isRunning을 다시 확인한 뒤 보낸다. 이미 끝나 회수된 pid는 다른 프로세스가 재사용할 수 있어서다.
        for process in alive where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return Self.waitForExit(alive, until: Date().addingTimeInterval(Self.killWait))
    }

    /// 앱 종료 때 SIGINT 뒤 기다리는 기본 시간(초). pytest가 중단 이벤트를 남기고 끝나기에 보통 충분하다.
    public static let terminationWait: TimeInterval = 2.5
    /// stopForTermination이 SIGINT 뒤 기다릴 수 있는 최대 시간(초). 메인 스레드를 오래 막지 않기 위한 상한이다.
    public static let maxTerminationWait: TimeInterval = 5
    /// SIGKILL 뒤 종료 확인을 기다리는 시간(초). SIGKILL은 막을 수 없어 보통 수 밀리초 안에 끝난다.
    static let killWait: TimeInterval = 0.5

    /// 모든 프로세스가 끝날 때까지 짧은 간격(20ms)으로 확인하며 마감 시각까지 기다린다.
    /// 런루프나 work 큐에 기대지 않고 sleep을 쓰는 이유: 메인 스레드에서 불려도
    /// 다른 큐의 도움 없이 끝나야 하기 때문이다. Process.isRunning은 Foundation 내부 큐가 갱신한다.
    /// - Parameters:
    ///   - processes: 기다릴 프로세스.
    ///   - deadline: 하나의 마감 시각. 프로세스마다 시간을 따로 주지 않는다.
    /// - Returns: 마감 전에 모두 끝났으면 true, 하나라도 살아 있으면 false.
    private static func waitForExit(_ processes: [Process], until deadline: Date) -> Bool {
        while processes.contains(where: { $0.isRunning }) {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// 이 앱이 시작한 실행 ID인지. 외부 실행 감시기가 부른다(어느 스레드에서든 안전).
    public func isAppRun(_ runID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return appRunIDs.contains(runID)
    }

    /// launch를 work 큐에 넣는 순서 규칙(launchOrderRule). start·startAll·대기 줄 꺼내기(complete) 모두 actives에
    /// "실행 중"(.waitingForEvents)을 적는 잠금 구간 안에서 launch를 work 큐에 넣는다. 그러면 stop(envID:)가 실행 중 표시를
    /// 본 순간 이미 launch가 큐에 있어, 뒤에 넣는 중지 작업은 언제나 launch 다음에 돈다(work 큐는 직렬이다).
    /// "띄우기 전 중지 요청" 집합을 따로 두는 방법은 쓰지 않았다. 이 순서 규칙만으로 중지가 launch보다 앞설 길이 없고,
    /// 집합을 두면 그것을 비우는 시점(실행 오류·종료 중 거절 등)마다 관리할 곳이 늘어난다.
    ///
    /// 테스트용: 대기 줄에서 꺼낸 직후(잠금 밖, 정리·알림 전) 불린다. 매개변수는 꺼낸 환경 id. work 큐에서 불리므로
    /// 이 안에서 stop(envID:)를 불러도 된다(잠금을 쥐고 있지 않다). 앱에서는 nil이다.
    var testHookAfterPromote: (([String]) -> Void)?

    /// 테스트용: 실행 ID → 지금 등록된 자식 프로세스의 pid.
    var childPIDs: [String: pid_t] {
        lock.lock(); defer { lock.unlock() }
        return runningProcesses.mapValues { $0.processIdentifier }
    }

    /// 테스트용: 그 환경에서 지금 등록된 자식 프로세스의 pid(없으면 nil).
    func childPID(envID: String) -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        guard let runID = state.actives[envID]?.runID else { return nil }
        return runningProcesses[runID]?.processIdentifier
    }

    // MARK: 내부(work 큐에서만)

    /// 자식 프로세스를 띄운다. 실패하면 그 환경만 launchFailed로 끝낸다.
    private func launch(_ request: PendingRun) {
        let runID = request.runID, envID = request.envID, pythonPath = request.pythonPath
        let projectPath = request.projectPath
        let ctx = Context(runID: runID, envID: envID, batchID: request.batchID,
                          eventsFile: paths.eventsFile(runID: runID))
        contexts[runID] = ctx
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
            p.terminationHandler = { [weak self] _ in self?.work.async { self?.finish(ctx, pythonPath: pythonPath) } }
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
            runningProcesses[runID] = p
            lock.unlock()
        } catch {
            try? ctx.logHandle?.close()
            contexts[runID] = nil
            complete(ctx, outcome: .launchFailed(message: "실행하지 못했습니다: \(error.localizedDescription)"), elapsed: nil)
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
    /// 자기 환경 키의 실행 ID가 같을 때만 바꾼다. 다른 환경이나 같은 환경의 다음 실행을 건드리지 않기 위함이다.
    private func poll(_ ctx: Context) {
        for line in ctx.tail.read() { ctx.progress.ingest(line) }
        let phase: RunPhase = ctx.progress.matchedEvents > 0
            ? .running(done: ctx.progress.done, total: ctx.progress.total)
            : (ctx.tail.fileSeen ? .running(done: 0, total: nil) : .waitingForEvents)
        let envID = ctx.envID, runID = ctx.runID
        if mutate({ s in
            if s.actives[envID]?.runID == runID, s.actives[envID]?.phase != phase { s.actives[envID]?.phase = phase }
        }) { publish() }
    }

    /// 프로세스가 끝난 뒤 결과를 확정한다. 순서가 중요하다:
    /// 1) 다른 run_id 이벤트가 섞였으면 오류, 2) 이벤트가 하나도 없으면 수집 실패,
    /// 3) 종료 이벤트가 없으면 미완료, 4) 그 외에는 집계기에 판정을 맡긴다.
    /// 종료 이벤트 없는 실행을 집계기에 넘기지 않는 이유: 강제 종료로 마지막 줄이 잘렸을 수 있어 집계가 오류를 낼 수 있다.
    private func finish(_ ctx: Context, pythonPath: String) {
        // 끝난 프로세스는 더 이상 신호 대상이 아니다. 같은 객체일 때만 지운다(다른 실행의 참조를 지우지 않도록).
        lock.lock()
        if runningProcesses[ctx.runID] === ctx.process { runningProcesses[ctx.runID] = nil }
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
        contexts[ctx.runID] = nil
        complete(ctx, outcome: outcome, elapsed: elapsed)
    }

    /// 판정은 Python 집계기를 1번 호출해 받는다. 외부 실행 감시기와 같은 함수(Aggregation.run)를 쓴다.
    private func aggregate(pythonPath: String, runID: String) -> RunOutcome {
        Aggregation.run(runner: runner, pythonPath: pythonPath, eventsFile: paths.eventsFile(runID: runID), runID: runID)
    }

    /// 결과를 저장하고 그 환경의 실행 중 표시를 지운 뒤, 대기 줄에서 다음 실행을 꺼내고, 오래된 파일을 정리하고 알린다.
    /// 매개변수 elapsed: pytest 프로세스의 실행 시간(초). 시작하지 못했으면 nil이고, 이때는 이전 값도 지운다
    /// (지우지 않으면 새 결과 옆에 지난 실행의 시간이 보인다).
    /// 바꾸는 것은 ctx.envID 키뿐이다. 한 실행의 실패·중지·launchFailed가 다른 환경 상태를 바꾸지 않는다.
    private func complete(_ ctx: Context, outcome: RunOutcome, elapsed: TimeInterval?) {
        let envID = ctx.envID, runID = ctx.runID
        lock.lock()
        state.results[envID] = outcome
        // 결과를 낸 실행 ID. 완료 알림이 같은 실행을 한 번만 보내는 기준이다(8단계).
        state.runIDs[envID] = runID
        // 낱개 실행 결과면 지운다. 남기면 지난 묶음 ID가 새 결과에 붙어 "함께 실행한 결과"로 잘못 묶인다.
        state.batchIDs[envID] = ctx.batchID
        state.elapsed[envID] = elapsed
        // 외부 실행 결과와 최신을 비교할 시각(RunSnapshot.merged).
        state.finishedAt[envID] = Date()
        // 실행 ID가 같을 때만 지운다. 다른 실행이 이 환경 키를 쓰고 있으면 그대로 둔다(방어 확인).
        if state.actives[envID]?.runID == runID { state.actives[envID] = nil }
        if let batchID = ctx.batchID { markBatchLocked(batchID, envID: envID, cancelled: false) }
        let next = promoteQueuedLocked()
        // 꺼낸 실행은 work 큐에 다시 넣어 띄운다. 여기서 바로 launch를 부르면, 그 실행도 launchFailed일 때
        // complete → launch → complete로 재귀가 깊어진다.
        // 반드시 꺼낸 것과 같은 잠금 안에서 넣는다(launchOrderRule). 예전에는 잠금을 푼 뒤 정리·알림 다음에 넣어서,
        // 그 틈에 메인의 stop(envID:)(아직 "차례 기다림"으로 보이는 행의 ■, [모두 중지])이 이미 .waitingForEvents인
        // 상태를 보고 중지 작업을 launch보다 먼저 큐에 넣었다. 중지 작업은 문맥이 없어 그냥 끝나고, 뒤이어 launch가
        // pytest를 띄워 중지가 조용히 사라졌다(9단계 리뷰 결함 1).
        for request in next { work.async { self.launch(request) } }
        pruneBatchesLocked()
        // 방금 끝난 실행과, 실행 중·대기 중인 실행 ID를 모두 보호한다(설계 2.2).
        let protected = Set(state.actives.values.map(\.runID)).union([runID])
        lock.unlock()
        // 테스트용 끼어들기 지점: 꺼내기 직후, 정리·알림 전. 예전 결함은 바로 이 틈에서 생겼다.
        testHookAfterPromote?(next.map(\.envID))
        FileCleaner.pruneAll(paths, keep: keep, protecting: protected)
        publish()
    }

    /// 자리가 난 만큼 대기 줄 앞에서 꺼내 "시작함"으로 바꾸고 돌려준다. `lock`을 쥔 채로 불러야 한다.
    /// 앱 종료 중이면 꺼내지 않는다(종료 뒤에 새 pytest가 뜨면 앱보다 오래 남는다).
    private func promoteQueuedLocked() -> [PendingRun] {
        guard !terminating else { return [] }
        var out: [PendingRun] = []
        while state.runningCount < runLimit, !pending.isEmpty {
            let request = pending.removeFirst()
            // 대기 표시가 그 실행 그대로일 때만 시작한다. 취소됐으면 actives에서 이미 빠져 있다.
            guard state.actives[request.envID]?.runID == request.runID else { continue }
            state.actives[request.envID]?.phase = .waitingForEvents
            // 경과 시간이 대기한 시간까지 세지 않게 실제 시작 시각으로 바꾼다.
            state.actives[request.envID]?.startedAt = Date()
            out.append(request)
        }
        return out
    }

    /// 묶음에 한 환경이 끝났거나(결과 있음) 취소됐다고 적는다. 모두 정해지면 끝난 시각을 남긴다. `lock`을 쥔 채로.
    private func markBatchLocked(_ batchID: String, envID: String, cancelled: Bool) {
        guard var batch = state.batches[batchID] else { return }
        if cancelled { batch.cancelledEnvIDs.insert(envID) } else { batch.completedEnvIDs.insert(envID) }
        if batch.finishedAt == nil && batch.isFinished { batch.finishedAt = Date() }
        state.batches[batchID] = batch
    }

    /// 끝났고 더 가리키는 결과·실행이 없는 묶음을 지운다. `lock`을 쥔 채로 부른다.
    /// 지우지 않으면 [모두 실행]을 누를 때마다 메모리에 묶음이 쌓인다. 결과가 그 묶음을 가리키는 동안은 남겨
    /// 캐릭터·알림·비교가 묶음 정보를 읽을 수 있게 한다.
    private func pruneBatchesLocked() {
        let referenced = Set(state.batchIDs.values).union(state.actives.values.compactMap(\.batchID))
        state.batches = state.batches.filter { id, batch in !batch.isFinished || referenced.contains(id) }
    }

    /// 정리에서 보호할 실행 ID(실행 중·대기 중 전부). 어느 스레드에서든 부를 수 있다.
    private func protectedRunIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(state.actives.values.map(\.runID))
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

    /// 지금 상태를 notifyQueue로 알린다. 어느 스레드에서든 부를 수 있다(잠금을 쥔 채로 부르면 안 된다. NSLock은 재진입하지 않는다).
    /// 상태 읽기와 notifyQueue에 넣기를 한 잠금 안에서 한다. 따로 하면 메인(start·startAll·대기 취소)과 work 큐(poll·complete)의
    /// publish가 겹칠 때, 먼저 읽은 옛 상태가 나중에 큐에 들어가 마지막 알림이 된다. 그러면 끝난 환경이 다음 상태 변화가
    /// 올 때까지 "실행 중"으로 남는다(9단계 리뷰 결함 2). 잠금 안에서 넣으면 큐에 들어가는 순서가 상태를 읽은 순서와 같다.
    /// notifyQueue가 직렬 큐여야 이 순서가 도착 순서로 이어진다(앱은 직렬 큐 "pmh.menu-notify", 기본값 .main도 직렬).
    /// notifyQueue.async는 넣기만 하고 바로 돌려주므로 잠금 안에서 불러도 받는 쪽(onChange)을 기다리지 않는다.
    /// onChange 안에서 snapshot을 읽어도 교착이 없다. onChange는 이 잠금을 푼 뒤 notifyQueue에서 돈다.
    private func publish() {
        lock.lock()
        let snap = state
        notifyQueue.async { self.onChange(snap) }
        lock.unlock()
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
