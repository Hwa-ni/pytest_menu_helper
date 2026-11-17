// ExternalRuns.swift
// 앱이 실행하지 않은 pytest(다른 터미널에서 실행한 것, "외부 실행")를 이벤트 폴더에서 찾아
// 등록한 프로젝트·환경에 연결하고, 진행과 결과를 모으는 코드(6단계).
// 입력: 이벤트 폴더(AppPaths.eventsDir, 앱과 플러그인이 공통 설정으로 정한 곳),
//       등록 정보에서 만든 매칭 대상(ProjectTarget 목록), 앱이 직접 시작한 실행인지 묻는 함수.
// 출력: ExternalSnapshot(환경별 진행 중인 외부 실행, 끝난 외부 실행의 결과, 등록하지 않은 환경의 실행).
//       알림은 notifyQueue로만 보낸다(앱에서는 메인 런루프로 다시 넘긴다).
//
// 설계 요약(자세한 이유는 docs/EVENTS.md "다른 터미널의 실행"):
// - 감시 방식: 0.5초마다 폴더 목록을 읽고(주기 읽기), 추적 중인 파일은 EventTail로 새 줄만 읽는다.
//   FSEvents·DispatchSource를 쓰지 않는 이유는 문서에 적었다(파일 내용 추가는 폴더 알림으로 오지 않고,
//   폴더 안 파일 수가 최대 50여 개라 목록 읽기 비용이 작으며, 앱 실행 읽기와 같은 방식이라 검증이 쉽다).
// - 외부 실행 식별: 파일 이름의 실행 ID가 앱이 시작한 실행 ID가 아니고, session_start에 parent_run_id가 없는 것.
//   parent_run_id가 있으면 테스트 안에서 다시 띄운 중첩 pytest라 바깥 실행의 일부로 보고 숨긴다.
// - 프로젝트 매칭: pytest를 실행한 폴더(invocation_dir)가 등록 프로젝트 폴더이거나 그 아래면 그 프로젝트.
//   맞는 프로젝트가 없으면 rootdir(project_root)로 한 번 더 본다. 여럿이면 가장 깊은(긴) 경로.
// - 환경 매칭: 같은 프로젝트의 환경 중 env.prefix(sys.prefix 실제 경로)가 검사 결과의 prefix와 같은 환경.
//   python 실제 경로는 쓰지 않는다. uv 가상환경은 기반 Python으로 풀려 여러 환경이 같은 값이 되기 때문이다.
// - 끝 판정: session_finish가 오면 그 환경의 집계기로 판정한다. 종료 이벤트 없이 프로세스가 사라졌으면
//   (pid와 프로세스 시작 시각으로 확인) 미완료. pid가 없어(구버전 플러그인) 확인할 수 없으면 "상태 확인 불가"로
//   남기고, 시간 초과로 실패 처리하지 않는다.

import CryptoKit
import Darwin
import Foundation

// MARK: 이벤트 시각

/// 플러그인 이벤트의 timestamp(Python datetime.isoformat, UTC)를 읽는다.
public enum EventTime {
    /// - Parameter text: 예 "2026-11-17T05:03:12.123456+00:00", 마이크로초가 0이면 "2026-11-17T05:03:12+00:00".
    /// - Returns: 시각. 형식이 다르면 nil.
    /// 소수점 아래를 직접 떼어 더하는 이유: ISO8601DateFormatter는 소수 자릿수(마이크로초 6자리)와
    /// 소수 없는 형식을 한 설정으로 함께 받지 못한다.
    public static func parse(_ text: String) -> Date? {
        var main = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            // 소수 부분은 점 뒤의 숫자들이다. 그 뒤(+00:00 또는 Z)는 시간대라 다시 붙인다.
            let afterDot = text[text.index(after: dot)...]
            let digits = afterDot.prefix(while: \.isNumber)
            guard !digits.isEmpty else { return nil }
            fraction = Double("0." + digits) ?? 0
            main = String(text[..<dot]) + String(afterDot.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let base = formatter.date(from: main) else { return nil }
        return base.addingTimeInterval(fraction)
    }
}

// MARK: session_start 정보

/// session_start 이벤트에서 외부 실행 연결에 쓰는 값만 뽑은 것.
/// 0.3.0 미만 플러그인은 pid·invocationDir·envPrefix·parentRunID가 없어 nil이다.
public struct SessionStartInfo: Equatable {
    public var runID: String
    public var timestamp: Date?
    public var pid: Int32?
    public var invocationDir: String?
    public var projectRoot: String?
    public var envID: String?
    public var envPrefix: String?
    public var pythonPath: String?
    public var parentRunID: String?

    public init(runID: String, timestamp: Date? = nil, pid: Int32? = nil, invocationDir: String? = nil,
                projectRoot: String? = nil, envID: String? = nil, envPrefix: String? = nil,
                pythonPath: String? = nil, parentRunID: String? = nil) {
        self.runID = runID; self.timestamp = timestamp; self.pid = pid; self.invocationDir = invocationDir
        self.projectRoot = projectRoot; self.envID = envID; self.envPrefix = envPrefix
        self.pythonPath = pythonPath; self.parentRunID = parentRunID
    }

    /// JSON 객체(이벤트 한 줄)에서 만든다.
    /// - Returns: event가 session_start가 아니거나 run_id가 없으면 nil.
    /// 숫자 pid는 JSONSerialization이 NSNumber로 주므로 Int로 받은 뒤 범위를 확인해 Int32로 바꾼다.
    public static func parse(_ object: [String: Any]) -> SessionStartInfo? {
        guard object["event"] as? String == "session_start", let runID = object["run_id"] as? String else { return nil }
        let env = object["env"] as? [String: Any]
        let pid = (object["pid"] as? Int).flatMap { $0 > 0 && $0 <= Int(Int32.max) ? Int32($0) : nil }
        return SessionStartInfo(
            runID: runID, timestamp: (object["timestamp"] as? String).flatMap(EventTime.parse), pid: pid,
            invocationDir: object["invocation_dir"] as? String, projectRoot: object["project_root"] as? String,
            envID: env?["id"] as? String, envPrefix: env?["prefix"] as? String,
            pythonPath: env?["python_path"] as? String, parentRunID: object["parent_run_id"] as? String)
    }
}

// MARK: 경로

public enum PathTools {
    /// 심볼릭 링크를 푼 실제 경로(POSIX realpath). 파일이 없어 풀 수 없으면 표준화한 경로를 돌려준다.
    /// Foundation의 resolvingSymlinksInPath를 쓰지 않는 이유: "/private/tmp"를 "/tmp"로 바꾸는 등
    /// Python os.path.realpath와 결과가 달라, 플러그인이 남긴 경로와 비교가 어긋난다.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// dir가 folder 자신이거나 그 아래인지. 끝에 "/"를 붙여 비교해 "/a/proj"가 "/a/project"에 맞지 않게 한다.
    public static func isInside(_ dir: String, folder: String) -> Bool {
        if dir == folder { return true }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return dir.hasPrefix(prefix)
    }
}

// MARK: 매칭

/// 매칭 대상 환경. prefix는 환경 검사 결과의 sys.prefix 실제 경로이며 검사 전이면 nil이다.
public struct EnvTarget: Equatable {
    public var id: String
    public var pythonPath: String
    public var prefix: String?
    public init(id: String, pythonPath: String, prefix: String?) {
        self.id = id; self.pythonPath = pythonPath; self.prefix = prefix
    }
}

/// 매칭 대상 프로젝트. path는 실제 경로로 풀어 둔 값이다(플러그인이 남기는 경로도 실제 경로).
public struct ProjectTarget: Equatable {
    public var id: UUID
    public var path: String
    public var environments: [EnvTarget]
    public init(id: UUID, path: String, environments: [EnvTarget]) {
        self.id = id; self.path = path; self.environments = environments
    }
}

public enum MatchResult: Equatable {
    /// 등록한 프로젝트와 환경에 연결됐다.
    case matched(projectID: UUID, envID: String)
    /// 프로젝트는 맞는데, 검사가 끝나지 않아 prefix를 모르는 환경이 있어 아직 판단할 수 없다.
    case waitingForCheck(projectID: UUID)
    /// 프로젝트는 맞지만 등록하지 않은 Python 환경에서 실행했다.
    case unregisteredEnvironment(projectID: UUID)
    /// 등록한 프로젝트 밖에서 실행했다.
    case noProject
}

public enum ExternalMatching {
    /// 플러그인이 PMH_ENV_ID 없이 쓰는 기본 환경 id(sys.prefix 실제 경로의 SHA-256 앞 12자리)를 같은 방식으로 만든다.
    /// 0.3.0 전 플러그인은 env.prefix를 남기지 않아 이 값으로 환경을 맞춘다.
    public static func defaultEnvID(prefix: String) -> String {
        SHA256.hash(data: Data(prefix.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// 실행이 속한 프로젝트를 고른다. invocation_dir을 먼저 보고, 맞는 프로젝트가 없을 때만 project_root를 본다.
    /// project_root(rootdir)를 나중에 보는 이유: 상위 폴더에 pytest 설정이 있으면 rootdir가 프로젝트보다 위가 되어
    /// 엉뚱한(더 바깥) 프로젝트에 맞을 수 있다. 실행한 폴더가 사용자의 의도에 더 가깝다.
    /// - Returns: 맞는 프로젝트 중 경로가 가장 긴(가장 안쪽) 것. 없으면 nil.
    public static func project(for start: SessionStartInfo, in projects: [ProjectTarget]) -> ProjectTarget? {
        for dir in [start.invocationDir, start.projectRoot].compactMap({ $0 }) {
            let hits = projects.filter { PathTools.isInside(dir, folder: $0.path) }
            if let best = hits.max(by: { $0.path.count < $1.path.count }) { return best }
        }
        return nil
    }

    /// 실행을 등록한 프로젝트·환경에 연결한다.
    /// 환경 판단 순서: 1) env.id가 등록 환경 id와 같음(사용자가 PMH_ENV_ID를 직접 준 경우)
    /// 2) env.prefix가 검사 결과 prefix와 같음 3) env.prefix가 없으면(구버전) env.id가 prefix 해시와 같음.
    /// 하나도 맞지 않는데 검사 전인 환경이 있으면 판단을 미룬다(앱 시작 직후 검사가 끝나기 전에 실행이 보일 수 있다).
    public static func match(_ start: SessionStartInfo, projects: [ProjectTarget]) -> MatchResult {
        guard let project = project(for: start, in: projects) else { return .noProject }
        let envs = project.environments
        if let id = start.envID, let env = envs.first(where: { $0.id == id }) {
            return .matched(projectID: project.id, envID: env.id)
        }
        if let prefix = start.envPrefix, let env = envs.first(where: { $0.prefix == prefix }) {
            return .matched(projectID: project.id, envID: env.id)
        }
        if start.envPrefix == nil, let id = start.envID,
           let env = envs.first(where: { $0.prefix.map(defaultEnvID) == id }) {
            return .matched(projectID: project.id, envID: env.id)
        }
        if envs.contains(where: { $0.prefix == nil }) { return .waitingForCheck(projectID: project.id) }
        return .unregisteredEnvironment(projectID: project.id)
    }

    /// 등록 정보와 검사 결과로 매칭 대상을 만든다.
    /// - Parameters:
    ///   - registry: 등록한 프로젝트·환경.
    ///   - checks: 환경 id → 검사 결과. 결과가 없거나 prefix를 읽지 못한 환경은 prefix가 nil이다.
    ///   - realPath: 경로를 실제 경로로 푸는 함수(테스트에서 바꿀 수 있다).
    public static func targets(registry: Registry, checks: [String: EnvCheck],
                               realPath: (String) -> String = PathTools.realPath) -> [ProjectTarget] {
        registry.projects.map { project in
            ProjectTarget(id: project.id, path: realPath(project.path), environments: project.environments.map {
                EnvTarget(id: $0.id, pythonPath: $0.pythonPath, prefix: checks[$0.id]?.report?.prefix.map(realPath))
            })
        }
    }
}

// MARK: 프로세스 생존 확인

public enum Liveness: Equatable {
    case alive
    case dead
}

public enum ProcessLiveness {
    /// pid의 프로세스가 아직 그 pytest인지 확인한다.
    /// - Parameters:
    ///   - pid: session_start의 pid.
    ///   - startedBy: session_start 시각. 프로세스는 그보다 먼저 시작했어야 한다.
    /// - Returns: 프로세스가 없거나, 좀비(끝났지만 회수 전)거나, 시작 시각이 session_start보다 2초 넘게 늦으면
    ///   dead(같은 pid를 다른 프로세스가 다시 쓴 경우), 그 밖에는 alive.
    /// kill(pid, 0) 대신 sysctl(KERN_PROC_PID)을 쓰는 이유: 시작 시각과 상태(좀비)도 함께 얻어 pid 재사용을 가릴 수 있다.
    /// 다른 사용자 프로세스여도 sysctl은 정보를 주므로 권한 문제로 dead로 잘못 보지 않는다.
    public static func check(pid: Int32, startedBy: Date?) -> Liveness {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return .dead }
        // 없는 pid는 sysctl이 성공하면서 크기 0을 돌려준다. 위에서 걸렀다.
        if info.kp_proc.p_stat == SZOMB { return .dead }
        if let startedBy = startedBy {
            let tv = info.kp_proc.p_un.__p_starttime
            let started = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
            if started > startedBy.addingTimeInterval(2) { return .dead }
        }
        return .alive
    }
}

// MARK: 외부 실행 상태 값

/// 결과가 어디서 실행된 것인지. 팝오버가 "터미널" 표시를 붙일 때 쓴다.
public enum RunSource: Equatable {
    case app
    case terminal
}

/// 진행 중인 외부 실행 하나.
public struct ExternalActive: Equatable {
    public var runID: String
    public var envID: String
    public var projectID: UUID
    /// 진행(끝난 테스트 / 수집 수). 수집 전이면 total이 nil.
    public var phase: RunPhase
    /// session_start 시각. 경과 시간에 쓴다.
    public var startedAt: Date?
    public var pid: Int32?
    /// pid로 살아 있음을 확인했는지. false면 구버전 플러그인이라 끝났는지 알 수 없다("상태 확인 불가").
    public var statusKnown: Bool

    public init(runID: String, envID: String, projectID: UUID, phase: RunPhase, startedAt: Date?,
                pid: Int32?, statusKnown: Bool) {
        self.runID = runID; self.envID = envID; self.projectID = projectID; self.phase = phase
        self.startedAt = startedAt; self.pid = pid; self.statusKnown = statusKnown
    }
}

/// 끝난 외부 실행의 결과.
public struct ExternalResult: Equatable {
    public var runID: String
    public var envID: String
    public var outcome: RunOutcome
    /// session_start부터 session_finish까지(이벤트 시각 기준). 종료 이벤트가 없으면 nil.
    public var elapsed: TimeInterval?
    /// 결과가 정해진 시각. 앱 실행 결과와 어느 쪽이 최신인지 가릴 때 쓴다.
    public var finishedAt: Date

    public init(runID: String, envID: String, outcome: RunOutcome, elapsed: TimeInterval?, finishedAt: Date) {
        self.runID = runID; self.envID = envID; self.outcome = outcome
        self.elapsed = elapsed; self.finishedAt = finishedAt
    }
}

/// 등록한 프로젝트에서, 등록하지 않은 Python 환경으로 실행한 pytest. 팝오버가 "환경을 추가하세요" 안내에 쓴다.
public struct UnregisteredRun: Equatable {
    public var runID: String
    public var projectID: UUID
    /// 플러그인이 남긴 sys.prefix(가상환경 폴더). 구버전이면 python 실제 경로를 대신 쓴다.
    public var environmentPath: String
    public var seenAt: Date

    public init(runID: String, projectID: UUID, environmentPath: String, seenAt: Date) {
        self.runID = runID; self.projectID = projectID; self.environmentPath = environmentPath; self.seenAt = seenAt
    }
}

/// 감시기가 알리는 상태 전체.
public struct ExternalSnapshot: Equatable {
    /// 진행 중인 외부 실행(시작 시각 순). 같은 환경에서 둘 이상 돌 수도 있다.
    public var active: [ExternalActive]
    /// 환경 id → 그 환경의 마지막 외부 실행 결과(나중에 끝난 것이 이긴다).
    public var results: [String: ExternalResult]
    /// 최근 등록하지 않은 환경의 실행(최신 5건, 최신이 앞).
    public var unregistered: [UnregisteredRun]

    public init(active: [ExternalActive] = [], results: [String: ExternalResult] = [:],
                unregistered: [UnregisteredRun] = []) {
        self.active = active; self.results = results; self.unregistered = unregistered
    }
}

// MARK: 집계 호출(앱 실행과 공용)

public enum Aggregation {
    public static let timeout: TimeInterval = 30

    /// 환경의 Python으로 집계기를 1번 호출해 판정을 받는다. 실패는 판정이 아니라 오류로 돌려준다.
    /// - Parameters:
    ///   - runner: 프로세스 실행기(테스트에서 바꾼다).
    ///   - pythonPath: 등록한 환경의 Python. 그 환경에 설치된 집계기를 쓴다.
    ///   - eventsFile: 실행 ID의 이벤트 파일.
    ///   - runID: 기대하는 실행 ID. 집계 결과의 run_id가 다르면 섞인 것으로 본다.
    public static func run(runner: ProcessRunning, pythonPath: String, eventsFile: URL, runID: String) -> RunOutcome {
        let out = runner.run(executable: pythonPath,
                             arguments: ["-I", "-m", "pytest_menu_helper.aggregate", eventsFile.path],
                             workingDirectory: "/", timeout: timeout)
        if out.timedOut { return .aggregationFailed(message: "집계가 \(Int(timeout))초 안에 끝나지 않았습니다.") }
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
}

// MARK: 감시기

/// 이벤트 폴더를 주기적으로 읽어 외부 실행을 찾고 상태를 알린다.
/// 모든 파일 읽기·집계 호출은 내부 직렬 큐(work)에서 한다. 공개 함수는 어느 스레드에서 불러도 된다.
public final class ExternalRunWatcher {
    public static let scanInterval: TimeInterval = 0.5
    /// 등록하지 않은 환경 안내에 남길 최대 건수.
    static let unregisteredLimit = 5

    private let eventsDir: URL
    private let runner: ProcessRunning
    private let interval: TimeInterval
    private let liveness: (Int32, Date?) -> Liveness
    private let isAppRun: (String) -> Bool
    private let notifyQueue: DispatchQueue
    private let onChange: (ExternalSnapshot) -> Void
    private let onLog: (String) -> Void
    private let now: () -> Date

    private let work = DispatchQueue(label: "pmh.external", qos: .utility)
    private let lock = NSLock()
    /// 마지막으로 알린 상태. lock으로 보호한다(snapshot 읽기는 다른 스레드에서 올 수 있다).
    private var published = ExternalSnapshot()
    // 아래는 work 큐 전용.
    private var state = ExternalSnapshot()
    private var targets: [ProjectTarget] = []
    private var files: [String: Tracked] = [:]
    private var firstScanDone = false
    private var timer: DispatchSourceTimer?

    /// 파일 하나의 추적 상태.
    private final class Tracked {
        enum Stage { case pending, active, finished, ignored }
        let runID: String
        var tail: EventTail
        var progress: RunProgress
        /// 첫 목록 읽기 때 이미 있던 파일인지. 앱을 켜기 전에 끝난 실행을 결과로 보이지 않게 하는 데 쓴다.
        let baseline: Bool
        var baselineDecided = false
        var stage: Stage = .pending
        var unregisteredRecorded = false
        init(runID: String, url: URL, baseline: Bool) {
            self.runID = runID
            tail = EventTail(url: url)
            progress = RunProgress(runID: runID)
            self.baseline = baseline
        }
    }

    /// - Parameters:
    ///   - eventsDir: 감시할 폴더(앱이 읽는 폴더와 같아야 한다).
    ///   - runner: 집계 호출용 프로세스 실행기.
    ///   - interval: 목록 읽기 간격(초).
    ///   - liveness: pid 생존 확인 함수(테스트에서 바꾼다).
    ///   - isAppRun: 앱이 시작한 실행 ID인지. 맞으면 그 파일은 외부 실행이 아니다(RunController가 읽는다).
    ///   - notifyQueue·onChange: 상태가 바뀌면 이 큐에서 onChange를 부른다.
    ///   - onLog: 감지·연결·결과 같은 사건을 한 줄로 알린다(앱은 시스템 로그에 남겨 검증에 쓴다).
    ///   - now: 현재 시각(테스트에서 바꾼다).
    public init(eventsDir: URL, runner: ProcessRunning = SystemProcessRunner(),
                interval: TimeInterval = ExternalRunWatcher.scanInterval,
                liveness: @escaping (Int32, Date?) -> Liveness = ProcessLiveness.check,
                isAppRun: @escaping (String) -> Bool, notifyQueue: DispatchQueue = .main,
                onChange: @escaping (ExternalSnapshot) -> Void, onLog: @escaping (String) -> Void = { _ in },
                now: @escaping () -> Date = Date.init) {
        self.eventsDir = eventsDir; self.runner = runner; self.interval = interval; self.liveness = liveness
        self.isAppRun = isAppRun; self.notifyQueue = notifyQueue; self.onChange = onChange
        self.onLog = onLog; self.now = now
    }

    public var snapshot: ExternalSnapshot { lock.lock(); defer { lock.unlock() }; return published }

    /// 주기 감시를 시작한다. 두 번 불러도 타이머는 하나다.
    public func start() {
        work.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.work)
            timer.schedule(deadline: .now(), repeating: self.interval)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        work.async { self.timer?.cancel(); self.timer = nil }
    }

    /// 매칭 대상을 바꾼다(등록 변경, 검사 완료 때). 다음 읽기부터 반영된다.
    public func updateTargets(_ targets: [ProjectTarget]) {
        work.async { self.targets = targets }
    }

    /// 지금 한 번 읽고 끝날 때까지 기다린다. 테스트와 개발 도구용이다. work 큐 안에서 부르면 안 된다(교착).
    public func scanNow() {
        work.sync { tick() }
    }

    // MARK: 내부(work 큐에서만)

    private func tick() {
        let fm = FileManager.default
        // 폴더가 없으면(아직 아무 실행도 없음) 빈 폴더로 본다. 첫 읽기 표시는 남겨 다음에 생긴 파일을 새 실행으로 본다.
        let names = (try? fm.contentsOfDirectory(atPath: eventsDir.path)) ?? []
        let runNames = Set(names.filter { FileCleaner.isRunFile($0, ext: "jsonl") })
        for name in runNames where files[name] == nil {
            let url = eventsDir.appendingPathComponent(name)
            // 심볼릭 링크·폴더는 건드리지 않는다(정리 규칙과 같다).
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let runID = String(name.dropLast(".jsonl".count))
            let tracked = Tracked(runID: runID, url: url, baseline: !firstScanDone)
            if isAppRun(runID) { tracked.stage = .ignored }
            files[name] = tracked
        }
        firstScanDone = true
        // 지워진 파일(정리됨)은 잊는다. 진행 중으로 보이던 실행이면 결과 없이 사라진다.
        for name in files.keys where !runNames.contains(name) {
            if let t = files.removeValue(forKey: name) { state.active.removeAll { $0.runID == t.runID } }
        }
        for t in files.values where t.stage == .pending || t.stage == .active {
            process(t)
        }
        publishIfChanged()
    }

    /// 파일 하나를 읽고 단계를 정한다. 순서: 앱 실행·중첩 제외 → 시작 전 파일 판정 → 매칭 → 끝 판정.
    private func process(_ t: Tracked) {
        for line in t.tail.read() { t.progress.ingest(line) }
        guard let start = t.progress.start else {
            // session_start가 없다. 앱을 켜기 전 파일이면 시작조차 못 한 오래된 기록이라 무시한다.
            // 새 파일이면 첫 줄이 아직 안 쓰였을 수 있어 기다린다.
            if t.baseline { t.stage = .ignored }
            return
        }
        // 파일을 찾은 뒤에 앱이 같은 ID로 시작했을 수도 있어 한 번 더 본다.
        if isAppRun(t.runID) { ignore(t, "앱 실행"); return }
        if let parent = start.parentRunID { ignore(t, "중첩 pytest(바깥 실행 \(parent))"); return }
        if t.baseline && !t.baselineDecided {
            t.baselineDecided = true
            // 앱을 켜기 전에 끝난 실행은 보여 주지 않는다(결과 보존은 11단계). 아직 살아 있는 실행만 이어서 본다.
            if t.progress.sawFinish { t.stage = .ignored; return }
            guard let pid = start.pid, liveness(pid, start.timestamp) == .alive else { t.stage = .ignored; return }
            onLog("앱 시작 전부터 실행 중인 외부 pytest를 이어서 봅니다: run=\(t.runID) pid=\(pid)")
        }
        let match = ExternalMatching.match(start, projects: targets)
        // 연결돼 있던 실행이 등록 변경(환경·프로젝트 제거)으로 더 이상 맞지 않으면 진행 표시를 거둔다.
        // 빠뜨리면 사라진 환경의 "실행 중"이 끝날 때까지 남는다.
        if case .matched = match {} else if t.stage == .active {
            t.stage = .pending
            state.active.removeAll { $0.runID == t.runID }
        }
        switch match {
        case .matched(let projectID, let envID):
            handleMatched(t, start: start, projectID: projectID, envID: envID)
        case .waitingForCheck:
            // 검사가 끝나면 다시 맞춰 본다. 그 전에 끝난 실행은 어느 환경인지 확정할 수 없어 버린다.
            if isOver(t, start) { ignore(t, "환경 검사 전에 끝남") }
        case .unregisteredEnvironment(let projectID):
            if !t.unregisteredRecorded {
                t.unregisteredRecorded = true
                let path = start.envPrefix ?? start.pythonPath ?? "(알 수 없는 환경)"
                state.unregistered.insert(UnregisteredRun(runID: t.runID, projectID: projectID,
                                                          environmentPath: path, seenAt: now()), at: 0)
                if state.unregistered.count > Self.unregisteredLimit {
                    state.unregistered.removeLast(state.unregistered.count - Self.unregisteredLimit)
                }
                onLog("등록하지 않은 환경의 실행: run=\(t.runID) project=\(projectID) env=\(path)")
            }
            // 끝날 때까지 계속 본다(그사이 사용자가 환경을 추가하면 연결된다).
            if isOver(t, start) { t.stage = .ignored }
        case .noProject:
            // 등록하지 않은 폴더의 실행. 그사이 프로젝트가 등록될 수 있어 끝날 때까지는 계속 본다.
            if isOver(t, start) { t.stage = .ignored }
        }
    }

    private func ignore(_ t: Tracked, _ reason: String) {
        t.stage = .ignored
        state.active.removeAll { $0.runID == t.runID }
        onLog("외부 실행에서 제외: run=\(t.runID) 이유=\(reason)")
    }

    /// 종료 이벤트를 받았거나 pid로 끝난 것을 확인했는지. pid가 없으면 알 수 없으므로 false.
    private func isOver(_ t: Tracked, _ start: SessionStartInfo) -> Bool {
        if t.progress.sawFinish { return true }
        guard let pid = start.pid else { return false }
        return liveness(pid, start.timestamp) == .dead
    }

    /// 연결된 실행의 진행·결과를 정한다.
    /// 프로세스가 사라졌으면 파일을 한 번 더 읽는다. 마지막 줄(session_finish)을 쓰고 바로 끝난 경우
    /// 이 읽기 없이 판정하면 정상 종료를 미완료로 잘못 볼 수 있다.
    private func handleMatched(_ t: Tracked, start: SessionStartInfo, projectID: UUID, envID: String) {
        if t.stage != .active {
            t.stage = .active
            onLog("외부 실행 연결: run=\(t.runID) project=\(projectID) env=\(envID) pid=\(start.pid.map(String.init) ?? "-")")
        }
        var dead = false
        if !t.progress.sawFinish, let pid = start.pid, liveness(pid, start.timestamp) == .dead {
            dead = true
            for line in t.tail.read() { t.progress.ingest(line) }
        }
        if t.progress.sawFinish {
            let outcome: RunOutcome
            if t.progress.foreignEvents > 0 {
                outcome = .eventsMixed(foreign: t.progress.foreignEvents)
            } else if let python = pythonPath(envID: envID) {
                outcome = Aggregation.run(runner: runner, pythonPath: python, eventsFile: t.tail.url, runID: t.runID)
            } else {
                outcome = .aggregationFailed(message: "환경 등록이 사라져 집계하지 못했습니다.")
            }
            let elapsed = zip2(start.timestamp, t.progress.finishedAt).map { $1.timeIntervalSince($0) }
            finish(t, envID: envID, outcome: outcome, elapsed: elapsed)
        } else if dead {
            // 종료 이벤트 없이 프로세스가 사라졌다(kill -9, 터미널 닫기 등). 종료 코드는 알 수 없다.
            let p = t.progress
            finish(t, envID: envID, outcome: .incomplete(termination: .unknown, stopped: false, done: p.done, total: p.total),
                   elapsed: nil)
        } else {
            let p = t.progress
            let phase: RunPhase = .running(done: p.done, total: p.total)
            let active = ExternalActive(runID: t.runID, envID: envID, projectID: projectID, phase: phase,
                                        startedAt: start.timestamp, pid: start.pid, statusKnown: start.pid != nil)
            if let i = state.active.firstIndex(where: { $0.runID == t.runID }) {
                state.active[i] = active
            } else {
                state.active.append(active)
                state.active.sort { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            }
        }
    }

    private func finish(_ t: Tracked, envID: String, outcome: RunOutcome, elapsed: TimeInterval?) {
        t.stage = .finished
        state.active.removeAll { $0.runID == t.runID }
        state.results[envID] = ExternalResult(runID: t.runID, envID: envID, outcome: outcome,
                                              elapsed: elapsed, finishedAt: now())
        onLog("외부 실행 결과: run=\(t.runID) env=\(envID) 결과=\(outcome.title)")
    }

    private func pythonPath(envID: String) -> String? {
        for p in targets { if let e = p.environments.first(where: { $0.id == envID }) { return e.pythonPath } }
        return nil
    }

    private func publishIfChanged() {
        lock.lock()
        let changed = published != state
        if changed { published = state }
        let snap = published
        lock.unlock()
        if changed { notifyQueue.async { self.onChange(snap) } }
    }
}

/// 두 선택 값이 모두 있을 때만 짝을 만든다.
private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a = a, let b = b else { return nil }
    return (a, b)
}
