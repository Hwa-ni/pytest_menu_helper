// pmh-run: 앱의 실행 로직(RunController)을 화면 없이 돌려 보는 개발용 명령줄 도구.
// 사용법: pmh-run <python 경로> <프로젝트 폴더> [--data-dir <폴더>] [--stop-after <초>]
// 입력: 등록한 환경의 python 하나와 프로젝트 폴더. 이 도구도 앱처럼 `python -m pytest`만 실행한다.
// 출력: 상태 변화(수집 대기, 실행 중 n/m)와 최종 결과를 표준 출력에 한 줄씩 적는다.
//       5단계부터 팝오버가 그릴 값(ResultPresentation.detail의 링·건수·실패 목록)도 [화면 ...] 줄로 적는다.
//       터미널 pytest 요약("1 failed, 1 passed")과 화면 건수가 같은지 눈으로 맞춰 보기 위함이다.
// 종료 코드: 0이면 결과를 받음, 2이면 인수 오류, 3이면 시작 거절/시간 초과.
import Foundation
import PMHCore

var args = Array(CommandLine.arguments.dropFirst())
var dataDir: String?
var stopAfter: Double?
// 옵션을 먼저 뽑고 남은 인수를 위치 인수로 쓴다.
func take(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
dataDir = take("--data-dir")
stopAfter = take("--stop-after").flatMap(Double.init)
guard args.count == 2 else {
    FileHandle.standardError.write(Data("사용법: pmh-run <python> <프로젝트 폴더> [--data-dir DIR] [--stop-after SEC]\n".utf8))
    exit(2)
}
let paths = dataDir.map { AppPaths(base: URL(fileURLWithPath: $0)) } ?? AppPaths.default
let done = DispatchSemaphore(value: 0)
var lastText = ""
// 알림은 별도 큐로 받는다(이 도구에는 메인 런루프가 없다).
let controller = RunController(paths: paths, notifyQueue: DispatchQueue(label: "pmh-run.notify")) { snap in
    if let a = snap.active {
        let text = a.stopping ? "중지하는 중 (\(a.phase.text))" : a.phase.text
        if text != lastText { lastText = text; print("[진행] \(text) run=\(a.runID)") }
    } else {
        done.signal()
    }
}
guard case .started(let runID) = controller.start(envID: "pmh-run", pythonPath: args[0], projectPath: args[1]) else {
    print("[거절] 이미 실행 중"); exit(3)
}
print("[시작] run=\(runID)")
if let delay = stopAfter {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { controller.stop() }
}
if done.wait(timeout: .now() + 300) == .timedOut { print("[시간 초과]"); exit(3) }
let outcome = controller.snapshot.results["pmh-run"]
print("[결과] \(outcome?.title ?? "없음")")
if let detail = outcome?.detail { print("[상세] \(detail)") }
// 팝오버 상세와 같은 함수로 화면 값을 만든다. 실행이 끝났으므로 active는 nil이다.
let screen = ResultPresentation.detail(envID: "pmh-run", active: nil, outcome: outcome,
                                       elapsed: controller.snapshot.elapsed["pmh-run"], blockedReason: nil)
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
print("[파일] events=\(paths.eventsFile(runID: runID).path)")
print("[파일] log=\(paths.logFile(runID: runID).path)")
