// Notifier.swift
// 8단계 완료 알림. UNUserNotificationCenter를 감싸 권한 읽기·요청, 알림 보내기, 알림 클릭 처리를 맡는다.
// 입력: AppDelegate가 pushPopoverState마다 넘기는 등록 정보와 합친 실행 상태(RunSnapshot.merged 결과).
// 출력: 알림 센터 요청, 시스템 로그(category notify), 권한 상태 변경 콜백(팝오버 안내 줄),
// 알림 클릭 콜백(팝오버를 그 환경으로 연다. 9단계 묶음 요약이면 환경 비교 절까지 보인다).
// 보낼지·문구는 PMHCore의 NotificationPresentation(순수 함수, 단위 테스트)이 정한다. 이 파일은 그 결정을 실행만 한다.
// 알림이 실제로 뜨려면 Bundle ID가 있는 .app + 서명(ad-hoc 이상) + open으로 실행이 모두 필요하다
// (docs/NOTIFICATION_BUNDLE.md). 번들 없이(swift run 등) UNUserNotificationCenter.current()를 부르면 앱이 죽으므로
// 번들 ID가 없으면 이 객체는 아무것도 하지 않는다.
// 로그 문구("알림 보냄 run=… 제목=…", "알림 보내지 않음(중단) run=…")는 통합 검증이 찾는 문자열이다
// (docs/APP.md 8단계). 바꾸면 문서의 확인 명령도 같이 바꾼다.

import AppKit
import os
import PMHCore
import Security
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let log = Logger(subsystem: "dev.yohwan.pytest-menu-helper", category: "notify")
    /// [완료 알림] 토글 저장 키(UserDefaults, 앱 번들 id 영역). 캐릭터 보이기 설정과 같은 곳에 둔다.
    static let enabledKey = "completionNotificationsEnabled"
    /// 알림 userInfo 키. 클릭했을 때 고를 환경 id.
    private static let envIDKey = "envID"
    /// 알림 userInfo 키(9단계). true면 클릭했을 때 팝오버의 "환경 비교" 절까지 스크롤한다(묶음 요약 알림).
    private static let comparisonKey = "showsComparison"

    /// 알림 센터. 번들 ID가 없으면 nil(위 파일 설명 참고).
    private let center: UNUserNotificationCenter?
    /// 이미 보냈거나 보내지 않기로 한 실행 ID와 묶음 ID(메인 스레드에서만 읽고 쓴다).
    /// 메모리에만 둔다. 앱을 다시 켜면 비지만, 결과도 메모리에만 있고 6단계 감시기가 앱 시작 전에 끝난 실행을
    /// 무시하므로 같은 실행을 다시 보낼 일이 없다(docs/STEP8_DESIGN.md 2.3).
    private var handled: Set<String> = []
    /// 마지막으로 읽은 권한 상태. 팝오버 안내 줄에 쓴다.
    private(set) var authorization: NotificationAuthorization = .unknown

    /// 권한 상태가 바뀌었을 때(메인 스레드). AppDelegate가 팝오버를 다시 그린다.
    var onAuthorizationChange: (NotificationAuthorization) -> Void = { _ in }
    /// 알림을 눌렀을 때(메인 스레드). 매개변수는 고를 환경 id와, 환경 비교 절까지 보일지(묶음 요약 알림이면 true).
    var onOpen: (String, Bool) -> Void = { _, _ in }

    /// [완료 알림] 토글. 기본은 켬. 바꾸면 바로 저장한다.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        // delegate는 앱 시작 직후에 걸어야 한다. 앱이 꺼진 상태에서 알림을 눌러 켜진 경우, 클릭 응답이
        // delegate가 걸리기 전에 도착하면 그 클릭을 놓친다.
        center?.delegate = self
    }

    // MARK: 권한

    /// 앱 시작 때 부른다. 권한 상태를 읽고, 아직 정하지 않은 상태(notDetermined)일 때만 한 번 요청한다.
    /// 거부된 상태에서 다시 요청하지 않는 이유: macOS는 두 번째 요청에 팝업을 띄우지 않고 바로 거부를 돌려준다.
    /// 사용자는 팝오버의 [설정 열기]로 시스템 설정에서 직접 허용해야 한다.
    /// 로그에 서명 식별값(cdhash)을 함께 남긴다. 다시 빌드한 뒤 권한이 유지되는지(설계 6절 위험) 확인하는 근거다.
    func start() {
        guard let center = center else {
            Self.log.error("알림 사용 불가: 번들 ID 없음(.app 번들로 실행해야 함)")
            return
        }
        center.getNotificationSettings { [weak self] settings in
            let status = Self.convert(settings.authorizationStatus)
            Self.log.notice("알림 권한 시작 상태=\(status.rawValue, privacy: .public) cdhash=\(Self.cdhash(), privacy: .public)")
            self?.deliver(status)
            guard status == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                Self.log.notice("알림 권한 요청 결과 granted=\(granted) error=\(String(describing: error), privacy: .public)")
                self?.refreshAuthorization()
            }
        }
    }

    /// 권한 상태를 다시 읽는다. 팝오버를 열 때 부른다(시스템 설정에서 바꾼 값을 반영하기 위함).
    func refreshAuthorization() {
        center?.getNotificationSettings { [weak self] settings in
            self?.deliver(Self.convert(settings.authorizationStatus))
        }
    }

    /// 권한 상태를 메인 스레드에서 저장하고, 바뀌었으면 알린다.
    /// 콜백은 알림 센터의 임의 스레드에서 오므로 메인 런루프 common 모드로 넘긴다(AppDelegate와 같은 규칙).
    private func deliver(_ status: NotificationAuthorization) {
        Self.onMain { [weak self] in
            guard let self = self, self.authorization != status else { return }
            Self.log.notice("알림 권한 상태 \(self.authorization.rawValue, privacy: .public) → \(status.rawValue, privacy: .public)")
            self.authorization = status
            self.onAuthorizationChange(status)
        }
    }

    // MARK: 보내기

    /// 새로 끝난 실행을 찾아 보낸다(메인 스레드에서 부른다). pushPopoverState마다 불러도 된다.
    /// - Parameters: registry(등록 정보), snapshot(합친 실행 상태).
    /// 결정은 NotificationPresentation.decisions가 하고, 결정한 ID(handledIDs: 낱개는 실행 ID, 묶음은 묶음 ID와
    /// 묶음의 실행 ID 전부)는 보내든 안 보내든 handled에 넣는다.
    /// 권한이 없으면 보내지 않고 "권한 없음"으로 남긴다. 권한 상태는 보낼 때 다시 읽는다.
    /// 시작 때 읽은 값만 믿으면 사용자가 시스템 설정에서 방금 허용한 것을 놓친다.
    func process(registry: Registry, snapshot: RunSnapshot) {
        let decisions = NotificationPresentation.decisions(registry: registry, snapshot: snapshot,
                                                           handled: handled, enabled: isEnabled)
        for decision in decisions {
            handled.formUnion(decision.handledIDs)
            switch decision {
            case .skip(let runID, let envID, let reason, _):
                Self.log.notice("알림 보내지 않음(\(reason, privacy: .public)) run=\(runID, privacy: .public) env=\(envID, privacy: .public)")
            case .send(let notice):
                send(notice)
            }
        }
    }

    /// 알림 한 건을 알림 센터에 넣는다. 권한이 없으면 넣지 않고 로그만 남긴다.
    private func send(_ notice: CompletionNotice) {
        guard let center = center else {
            Self.log.notice("알림 보내지 않음(번들 없음) run=\(notice.identifier, privacy: .public)")
            return
        }
        center.getNotificationSettings { [weak self] settings in
            let status = Self.convert(settings.authorizationStatus)
            self?.deliver(status)
            guard status.allowsDelivery else {
                Self.log.notice("알림 보내지 않음(권한 없음: \(status.rawValue, privacy: .public)) run=\(notice.identifier, privacy: .public) 제목=\(notice.title, privacy: .public)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            content.userInfo = [Self.envIDKey: notice.envID, Self.comparisonKey: notice.showsComparison]
            // identifier를 실행 ID로 준다. 같은 실행이 어떤 이유로 다시 들어와도 알림 센터가 덮어쓴다(이중 안전장치).
            let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
            center.add(request) { error in
                if let error = error {
                    Self.log.error("알림 보내기 실패 run=\(notice.identifier, privacy: .public) error=\(String(describing: error), privacy: .public)")
                } else {
                    let body = notice.body.replacingOccurrences(of: "\n", with: " / ")
                    Self.log.notice("알림 보냄 run=\(notice.identifier, privacy: .public) 제목=\(notice.title, privacy: .public) 본문=\(body, privacy: .public)")
                }
            }
        }
    }

    // MARK: 알림 센터 delegate

    /// 앱이 앞에 있을 때도 배너를 보인다. 돌려주지 않으면 macOS는 앞에 있는 앱의 알림을 화면에 띄우지 않는다
    /// (팝오버를 열어 둔 채 결과를 기다리면 앱이 앞에 있는 상태다. 결정 3: 팝오버가 열려 있어도 보냄).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// 알림을 눌렀을 때. 그 실행의 환경 id를 꺼내 메인 스레드에서 onOpen으로 넘긴다.
    /// completionHandler는 반드시 불러야 한다. 부르지 않으면 시스템이 응답 처리가 끝나지 않은 것으로 본다.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let envID = info[Self.envIDKey] as? String
        // 8단계 알림에는 이 키가 없다. 없으면 false(환경 상세만)로 본다.
        let comparison = info[Self.comparisonKey] as? Bool ?? false
        let runID = response.notification.request.identifier
        Self.log.notice("알림 클릭 run=\(runID, privacy: .public) env=\(envID ?? "-", privacy: .public) 비교=\(comparison)")
        if let envID = envID {
            Self.onMain { [weak self] in self?.onOpen(envID, comparison) }
        }
        completionHandler()
    }

    // MARK: 도구

    /// 시스템 설정의 알림 화면을 연다. 이 앱 항목으로 바로 가는 주소를 먼저 쓰고, 실패하면 알림 화면 첫 페이지를 연다.
    /// 주소가 둘인 이유: macOS 13부터 시스템 설정 주소 형식이 바뀌었고, 버전에 따라 id 매개변수를 무시한다.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.yohwan.pytest-menu-helper"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for text in candidates {
            if let url = URL(string: text), NSWorkspace.shared.open(url) {
                log.notice("시스템 설정 열기: \(text, privacy: .public)")
                return
            }
        }
        log.error("시스템 설정 알림 화면을 열지 못했습니다")
    }

    /// UNAuthorizationStatus를 PMHCore 값으로 바꾼다. 모르는 값(향후 macOS 추가)은 unknown.
    static func convert(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }

    /// 실행 중인 앱 번들의 서명 cdhash(16진수). 읽지 못하면 "-".
    /// ad-hoc 서명은 바이너리가 바뀔 때마다 이 값이 바뀐다. 권한 유지 시험에서 "다른 빌드였는지"를 로그로 보이기 위함이다.
    static func cdhash() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code = code else { return "-" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let data = dict[kSecCodeInfoUnique as String] as? Data else { return "-" }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// 메인 런루프 common 모드로 넘긴다. DispatchQueue.main을 쓰지 않는 이유는 AppDelegate.runStateArrived와 같다
    /// (팝오버 안 메뉴가 열려 있는 동안에도 처리되게). PerformBlock은 런루프를 깨우지 않으므로 직접 깨운다.
    private static func onMain(_ block: @escaping () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(main)
    }
}
