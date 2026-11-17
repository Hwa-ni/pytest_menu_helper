import Foundation
import UserNotifications

// 알림 샘플: 권한 요청 -> 허용 시 알림 1건 -> 결과 출력 후 종료.
setvbuf(stdout, nil, _IOLBF, 0)
print("bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")")

let center = UNUserNotificationCenter.current()
let done = DispatchSemaphore(value: 0)

func statusName(_ s: UNAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    default: return "other(\(s.rawValue))"
    }
}

center.requestAuthorization(options: [.alert, .sound]) { granted, error in
    print("requestAuthorization granted=\(granted) error=\(String(describing: error))")
    center.getNotificationSettings { settings in
        print("authorizationStatus=\(statusName(settings.authorizationStatus))")
        guard granted else { done.signal(); return }
        let content = UNMutableNotificationContent()
        content.title = "pytest Menu Helper 샘플"
        content.body = "알림이 표시되면 번들 설정이 올바른 것입니다."
        let req = UNNotificationRequest(identifier: "sample-\(UUID().uuidString)",
                                        content: content, trigger: nil)
        center.add(req) { err in
            print("add result=\(err == nil ? "success" : "error: \(err!)")")
            done.signal()
        }
    }
}
// 콜백이 오지 않는 경우를 대비해 20초 제한.
if done.wait(timeout: .now() + 20) == .timedOut { print("timeout"); exit(2) }
Thread.sleep(forTimeInterval: 1) // 배너가 큐에 들어갈 시간
