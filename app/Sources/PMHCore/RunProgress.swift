// RunProgress.swift
// 실행 중 진행률(끝난 테스트 수 / 전체 수)만 세는 코드.
// 입력: 이벤트 한 줄(JSON 바이트)과 앱이 정한 실행 ID.
// 출력: 끝난 테스트 수, 전체 수, 종료 이벤트 수신 여부, 다른 실행 ID 이벤트 수.
//       6단계부터 session_start 정보(SessionStartInfo)와 session_finish 시각도 담는다(외부 실행 연결·소요 시간용).
// 주의: 성공·실패 같은 판정 규칙은 여기에 두지 않는다. 최종 판정은 Python 집계기가 한다.

import Foundation

/// 실행 중 진행률만 센다. 판정 규칙은 두지 않는다(최종 판정은 Python 집계기).
/// 앱이 정한 run_id와 다른 이벤트는 세지 않고 `foreignEvents`로 따로 센다.
public struct RunProgress: Equatable {
    public let runID: String
    public private(set) var total: Int?
    public private(set) var done = 0
    public private(set) var matchedEvents = 0
    public private(set) var foreignEvents = 0
    public private(set) var malformedLines = 0
    public private(set) var sawFinish = false
    /// 첫 session_start의 정보. 외부 실행을 프로젝트·환경에 연결하고 생존을 확인하는 데 쓴다.
    public private(set) var start: SessionStartInfo?
    /// session_finish의 시각. 외부 실행 소요 시간(시작~종료 이벤트)에 쓴다.
    public private(set) var finishedAt: Date?
    private var finished: Set<String> = []

    public init(runID: String) { self.runID = runID }

    public mutating func ingest(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            malformedLines += 1
            return
        }
        guard object["run_id"] as? String == runID else {
            foreignEvents += 1
            return
        }
        matchedEvents += 1
        switch object["event"] as? String {
        case "session_collected":
            if let ids = object["nodeids"] as? [Any] { total = ids.count }
        case "test_report":
            // setup/call/teardown을 3건으로 세지 않도록 teardown까지 끝난 테스트만 센다.
            if object["phase"] as? String == "teardown", let node = object["nodeid"] as? String {
                let occurrence = (object["occurrence"] as? Int) ?? 1
                finished.insert("\(node)#\(occurrence)")
                done = finished.count
            }
        case "session_start":
            // 같은 파일에 session_start가 두 번이면(파일 재사용 등) 첫 값을 지킨다.
            if start == nil { start = SessionStartInfo.parse(object) }
        case "session_finish":
            sawFinish = true
            finishedAt = (object["timestamp"] as? String).flatMap(EventTime.parse)
        default:
            break
        }
    }
}
