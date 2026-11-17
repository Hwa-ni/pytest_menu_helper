// pmh-run: 앱의 실행 로직(RunController)을 화면 없이 돌려 보는 개발용 명령줄 도구.
// 사용법: pmh-run <python 경로> <프로젝트 폴더> [--data-dir <폴더>] [--stop-after <초>]
// 입력: 등록한 환경의 python 하나와 프로젝트 폴더. 이 도구도 앱처럼 `python -m pytest`만 실행한다.
// 출력: 상태 변화(수집 대기, 실행 중 n/m)와 최종 결과를 표준 출력에 한 줄씩 적는다.
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
print("[파일] events=\(paths.eventsFile(runID: runID).path)")
print("[파일] log=\(paths.logFile(runID: runID).path)")
