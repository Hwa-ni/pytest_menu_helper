// pmh-run: 앱의 실행 로직(RunController)을 화면 없이 돌려 보는 개발용 명령줄 도구.
// 사용법 1(환경 하나, 이전과 같음):
//   pmh-run <python 경로> <프로젝트 폴더> [--data-dir <폴더>] [--stop-after <초>]
// 사용법 2(9단계, 여러 환경 동시 실행):
//   pmh-run --env <이름>=<python 경로> [--env <이름>=<python 경로> ...] <프로젝트 폴더>
//           [--data-dir <폴더>] [--stop-after <초> [--stop-env <이름>]] [--max <동시 실행 수>]
//   --env를 여러 번 주면 [모두 실행]과 같은 RunController.startAll로 한 묶음으로 시작한다. 이름이 환경 id다.
//   --stop-after만 주면 그 시각에 모든 환경을 멈추고(stopAll), --stop-env를 함께 주면 그 환경만 멈춘다.
//   --max로 동시 실행 상한을 줄이면 넘치는 환경이 차례를 기다렸다가 시작하는지 볼 수 있다(기본 10).
// 입력: 등록한 환경의 python과 프로젝트 폴더. 이 도구도 앱처럼 `python -m pytest`만 실행한다.
// 출력: 상태 변화(차례 기다림, 수집 대기, 실행 중 n/m)와 최종 결과를 표준 출력에 한 줄씩 적는다.
//       사용법 1은 팝오버가 그릴 값(ResultPresentation.detail의 링·건수·실패 목록)도 [화면 ...] 줄로 적는다.
//       사용법 2는 환경별 결과 줄과 총 시간(벽시계), 환경별 소요 시간의 합을 적는다.
//       합보다 총 시간이 짧으면 순차가 아니라 동시에 돌았다는 뜻이다.
//       이어서 팝오버·캐릭터·알림과 같은 함수로 만든 값을 [비교 ...]·[캐릭터]·[알림] 줄로 적는다
//       (EnvComparison.build, CharacterPresentation.state, NotificationPresentation.decisions). 화면 없이
//       "3.9만 실패, 3.13 통과"가 비교 표·묶음 문구·요약 알림에 어떻게 보이는지 확인하기 위함이다.
//       이 줄들의 환경 이름은 --env의 이름이고, Python 버전 칸은 검사를 하지 않으므로 "검사 중"으로 나온다.
// 종료 코드: 0이면 결과를 받음, 2이면 인수 오류, 3이면 시작 거절/시간 초과.
import Foundation
import PMHCore

var args = Array(CommandLine.arguments.dropFirst())

/// 값 하나를 받는 옵션을 뽑아 낸다. 같은 옵션이 여러 번 있으면 첫 번째만 쓴다.
/// - Returns: 옵션 값. 옵션이 없거나 값이 빠졌으면 nil.
func take(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

/// 같은 옵션을 여러 번 받을 때 모두 뽑아 낸다(입력 순서 유지).
func takeAll(_ name: String) -> [String] {
    var values: [String] = []
    while let v = take(name) { values.append(v) }
    return values
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let usage = """
사용법: pmh-run <python> <프로젝트 폴더> [--data-dir DIR] [--stop-after SEC]
       pmh-run --env 이름=python [--env 이름=python ...] <프로젝트 폴더> [--data-dir DIR] [--stop-after SEC [--stop-env 이름]] [--max N]
"""

// 옵션을 먼저 뽑고 남은 인수를 위치 인수로 쓴다.
let dataDir = take("--data-dir")
let stopAfter = take("--stop-after").flatMap(Double.init)
let stopEnv = take("--stop-env")
let maxRuns = take("--max").flatMap(Int.init)
let envSpecs = takeAll("--env")

// --env 이름=경로. 경로의 ~는 셸이 펼치지 않을 수 있어(= 뒤의 ~) 여기서 펼친다.
// 빠뜨리면 "~/.venvs/..."를 그대로 실행하려다 실행 오류가 난다.
var targets: [RunTarget] = []
for spec in envSpecs {
    guard let eq = spec.firstIndex(of: "="), eq != spec.startIndex else { fail("--env 값은 이름=python경로 꼴이어야 합니다: \(spec)") }
    let name = String(spec[..<eq])
    let python = (String(spec[spec.index(after: eq)...]) as NSString).expandingTildeInPath
    if targets.contains(where: { $0.envID == name }) { fail("같은 환경 이름을 두 번 줬습니다: \(name)") }
    targets.append(RunTarget(envID: name, pythonPath: python))
}

let multi = !targets.isEmpty
// 사용법 1은 위치 인수 2개(python, 폴더), 사용법 2는 1개(폴더)다.
guard args.count == (multi ? 1 : 2) else { fail(usage) }
if stopEnv != nil && !multi { fail("--stop-env는 --env와 함께만 씁니다.\n" + usage) }
if let s = stopEnv, !targets.contains(where: { $0.envID == s }) { fail("--stop-env \(s)는 --env에 없는 이름입니다.") }
if stopEnv != nil && stopAfter == nil { fail("--stop-env는 --stop-after와 함께 줘야 합니다.") }
if multi && (maxRuns ?? 1) < 1 { fail("--max는 1 이상이어야 합니다.") }
let projectPath = (args[multi ? 0 : 1] as NSString).expandingTildeInPath

let paths = dataDir.map { AppPaths(base: URL(fileURLWithPath: $0)) } ?? AppPaths.default
let done = DispatchSemaphore(value: 0)
/// 환경 id → 마지막으로 찍은 진행 문구. 같은 문구를 반복해서 찍지 않기 위함이다.
var lastText: [String: String] = [:]
/// 시작 요청을 보낸 뒤에만 "모두 끝남"을 판단한다. 시작 전 빈 상태 알림으로 끝났다고 오판하지 않게 한다.
var armed = false
let wallStart = Date()

// 알림은 별도 직렬 큐로 받는다(이 도구에는 메인 런루프가 없다). 아래 변수는 이 큐에서만 바꾼다.
let notifyQueue = DispatchQueue(label: "pmh-run.notify")
let controller = RunController(paths: paths, maxConcurrentRuns: maxRuns ?? RunController.maxConcurrentRuns,
                               notifyQueue: notifyQueue) { snap in
    for (envID, a) in snap.actives.sorted(by: { $0.key < $1.key }) {
        let text = a.stopping ? "중지하는 중 (\(a.phase.text))" : a.phase.text
        if text != lastText[envID] {
            lastText[envID] = text
            print(multi ? "[진행 \(envID)] \(text)" : "[진행] \(text) run=\(a.runID)")
        }
    }
    if armed && snap.actives.isEmpty { done.signal() }
}

if multi {
    let r = controller.startAll(envs: targets, projectPath: projectPath)
    notifyQueue.sync { armed = true }
    guard let batchID = r.batchID else { print("[거절] 시작한 환경이 없습니다"); exit(3) }
    print("[묶음] \(batchID) · 시작 \(r.started.joined(separator: ", "))"
          + (r.queued.isEmpty ? "" : " · 차례 기다림 \(r.queued.joined(separator: ", "))"))
    for t in targets { print("[시작] \(t.envID) run=\(r.runIDs[t.envID] ?? "-") python=\(t.pythonPath)") }
    // startAll이 알린 상태가 이미 비었을 수도 있어(아주 빨리 모두 실패) 한 번 더 확인한다.
    notifyQueue.async { if controller.snapshot.actives.isEmpty { done.signal() } }
} else {
    let result = controller.start(envID: "pmh-run", pythonPath: args[0], projectPath: projectPath)
    notifyQueue.sync { armed = true }
    guard case .started(let runID) = result else { print("[거절] \(result)"); exit(3) }
    print("[시작] run=\(runID)")
    notifyQueue.async { if controller.snapshot.actives.isEmpty { done.signal() } }
}

if let delay = stopAfter {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
        if let env = stopEnv {
            print("[중지 요청] \(env)")
            controller.stop(envID: env)
        } else if multi {
            print("[중지 요청] 모든 환경")
            controller.stopAll()
        } else {
            controller.stop(envID: "pmh-run")
        }
    }
}
if done.wait(timeout: .now() + 300) == .timedOut { print("[시간 초과]"); exit(3) }
let wall = Date().timeIntervalSince(wallStart)
let snap = controller.snapshot

if multi {
    var sum: TimeInterval = 0
    for t in targets {
        let outcome = snap.results[t.envID]
        let elapsed = snap.elapsed[t.envID]
        sum += elapsed ?? 0
        let screen = ResultPresentation.detail(envID: t.envID, active: nil, outcome: outcome,
                                               elapsed: elapsed, blockedReason: nil)
        print("[결과 \(t.envID)] \(outcome?.title ?? "없음") · 소요 \(screen.elapsedText) · 묶음 \(snap.batchIDs[t.envID] ?? "-")")
        if let detail = outcome?.detail { print("[상세 \(t.envID)] \(detail)") }
        for entry in screen.failures {
            print("[실패 \(t.envID)] \(entry.statusLabel) \(entry.title) @ \(entry.locationText ?? "-") : \(entry.summary ?? "")")
        }
        if let runID = snap.runIDs[t.envID] {
            print("[파일 \(t.envID)] events=\(paths.eventsFile(runID: runID).path)")
        }
    }
    let batchDone = snap.batchIDs.values.first.flatMap { snap.batches[$0] }?.isFinished
    print(String(format: "[총 시간] %.1f초 · 환경별 소요 합 %.1f초 · 묶음 끝남 %@", wall, sum,
                 batchDone.map { $0 ? "예" : "아니오" } ?? "-"))
    // 앱 화면과 같은 함수로 만든 값. 등록 정보는 --env 이름을 환경 이름·id로 쓴 임시 프로젝트 하나다.
    let project = Project(path: projectPath, environments: targets.map {
        PMHEnvironment(id: $0.envID, name: $0.envID, pythonPath: $0.pythonPath)
    })
    let registry = Registry(projects: [project])
    if let cmp = EnvComparison.build(project: project, checks: [:], snapshot: snap, selectedEnvID: targets.first?.envID) {
        print("[비교] 열 \(cmp.columns.map(\.name).joined(separator: ", ")) · \(cmp.relationText ?? "-")")
        if let warning = cmp.warning { print("[비교 경고] \(warning)") }
        for note in cmp.notes { print("[비교 안내] \(note)") }
        for row in cmp.differingRows {
            let cells = zip(cmp.columns, row.cells).map { "\($0.0.name)=\($0.1.label)" }.joined(separator: " ")
            print("[비교 다름] \(row.title) : \(cells)")
        }
        print("[비교 같음] \(cmp.sameSummary ?? "없음")")
    } else {
        print("[비교] 결과가 있는 환경이 2개 미만이라 비교 절이 보이지 않습니다")
    }
    let character = CharacterPresentation.state(registry: registry, snapshot: snap)
    print("[캐릭터] pose=\(character.pose.rawValue) label=\(character.label) env=\(character.envID ?? "-")")
    for line in character.help.split(separator: "\n") { print("[캐릭터 도움말] \(line)") }
    for decision in NotificationPresentation.decisions(registry: registry, snapshot: snap, handled: [], enabled: true) {
        switch decision {
        case .send(let n): print("[알림] id=\(n.identifier) env=\(n.envID) 제목=\(n.title) 본문=\(n.body.replacingOccurrences(of: "\n", with: " / "))")
        case .skip(let id, _, let reason, _): print("[알림 안 보냄] id=\(id) 이유=\(reason)")
        }
    }
    exit(0)
}

let outcome = snap.results["pmh-run"]
print("[결과] \(outcome?.title ?? "없음")")
if let detail = outcome?.detail { print("[상세] \(detail)") }
// 팝오버 상세와 같은 함수로 화면 값을 만든다. 실행이 끝났으므로 active는 nil이다.
let screen = ResultPresentation.detail(envID: "pmh-run", active: nil, outcome: outcome,
                                       elapsed: snap.elapsed["pmh-run"], blockedReason: nil)
print("[화면 제목] \(screen.headline)")
print("[화면 링] 진행 \(screen.progressRing.center) · 통과율 \(screen.passRing.center) (\(screen.passRing.caption)) · 소요 \(screen.elapsedText)")
if !screen.counts.isEmpty {
    print("[화면 건수] " + screen.counts.map { "\($0.label) \($0.value)" }.joined(separator: " · "))
}
for entry in screen.failures {
    print("[화면 실패] \(entry.statusLabel) \(entry.title) @ \(entry.locationText ?? "-") : \(entry.summary ?? "")")
    // traceback은 길어서 줄 수와 마지막 줄만 적는다(화면에서는 전체를 스크롤해 본다).
    for section in entry.sections {
        let lines = section.detail?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
        print("[화면 상세]   \(section.title): traceback \(lines.count)줄, 마지막 줄: \(lines.last.map(String.init) ?? "-")")
    }
}
for note in screen.notes { print("[화면 안내] \(note)") }
if let runID = snap.runIDs["pmh-run"] {
    print("[파일] events=\(paths.eventsFile(runID: runID).path)")
    print("[파일] log=\(paths.logFile(runID: runID).path)")
}
