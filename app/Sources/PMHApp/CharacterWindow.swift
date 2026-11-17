// CharacterWindow.swift
// 7단계 캐릭터 창. 투명한 작은 창에 여우 SVG를 띄우고, pytest 상태에 따라 포즈(대기·달리기·성공·실패·갸웃)를 바꾼다.
// 입력: CharacterState(PMHCore CharacterPresentation.state가 만든 값), 사용자의 클릭·끌기, 보이기 설정.
// 출력: 화면의 캐릭터, 클릭 알림(onClick, AppDelegate가 결과 팝오버를 연다), 저장한 창 위치(UserDefaults).
// 렌더러는 WKWebView(투명 배경)다. NSImage는 SVG를 첫 장면 한 장으로만 그려 CSS 애니메이션(달리기·점프·넘어짐)을
// 재생하지 못한다(2026-11-17 확인, docs/CHARACTER.md "렌더러"). 에셋을 프레임으로 잘라 두는 방법은
// 새 그림마다 프레임을 다시 만들어야 해서 쓰지 않았다.
// 창은 테두리 없는 비활성 NSPanel이다. 눌러도 앱이 앞으로 나오지 않고 다른 앱의 키보드 입력을 빼앗지 않는다.
// 마우스는 WKWebView 위에 덮은 투명 뷰(CharacterHitView)가 모두 받는다. 웹뷰가 받으면 그림이 선택되거나
// 끌어 놓기(drag and drop)가 시작되고, 창 끌기와 클릭을 구분할 수 없다.

import AppKit
import os
import PMHCore
import WebKit

/// 키 창이 되지 않는 패널. 캐릭터를 눌러도 지금 쓰는 앱의 입력 포커스를 가져가지 않게 한다.
final class CharacterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 캐릭터 창 전체를 맡는다. AppDelegate가 하나 만들어 상태가 바뀔 때마다 apply를 부른다.
final class CharacterWindowController: NSObject, WKNavigationDelegate {
    /// 창 크기(pt). 그림 영역 168x112 + 아래 상태 글씨 자리(CharacterPage.labelHeight).
    /// 여우는 높이 112에 맞춰 그려져 폭 112만 쓰고, 남는 폭은 상태 글씨("미완료 · 중지함 · 터미널" 같은 긴 행 문구)를 위한 것이다.
    /// 이보다 긴 글씨는 페이지가 말줄임(…)으로 자르고, 전체 문구는 도움말(마우스 올리기)에 남는다.
    static let size = NSSize(width: CGFloat(CharacterPage.windowWidth), height: 112 + CGFloat(CharacterPage.labelHeight))
    /// 위치·보이기 저장 키. UserDefaults(앱 번들 id 영역)에 둔다. config.json은 플러그인과 같이 읽는 파일이라
    /// 화면 설정을 섞지 않는다(docs/CHARACTER.md "위치 기억").
    private static let originXKey = "characterOriginX"
    private static let originYKey = "characterOriginY"
    static let visibleKey = "characterVisible"

    static let log = Logger(subsystem: "dev.yohwan.pytest-menu-helper", category: "character")

    /// 캐릭터를 눌렀을 때(끌기가 아닌 클릭). 매개변수는 기준으로 쓸 뷰(팝오버를 이 뷰 옆에 연다)와 지금 상태.
    var onClick: (NSView, CharacterState) -> Void = { _, _ in }

    private let panel: CharacterPanel
    private let webView: WKWebView
    private let hitView: CharacterHitView
    /// 페이지 로드가 끝났는지. 끝나기 전의 evaluateJavaScript는 setPose가 아직 없어 실패하므로 끝난 뒤 한 번에 넣는다.
    private var pageLoaded = false
    /// 마지막으로 받은 상태. 같은 상태면 페이지에 다시 넣지 않는다.
    private(set) var state: CharacterState = .idle
    private var appliedState: CharacterState?

    /// 팝오버를 캐릭터 옆에 열 때 기준으로 쓸 뷰(8단계 알림 클릭에서 쓴다). 클릭 때 onClick이 넘기는 뷰와 같다.
    var anchorView: NSView { hitView }

    /// 보이기 설정. 기본값은 보임(사용자 결정 1=A). 바꾸면 바로 저장한다.
    var isVisible: Bool {
        get { UserDefaults.standard.object(forKey: Self.visibleKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.visibleKey)
            updateVisibility()
        }
    }

    override init() {
        let frame = NSRect(origin: .zero, size: Self.size)
        panel = CharacterPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        // 자바스크립트는 포즈를 바꾸는 setPose에만 쓴다. 외부 페이지를 열지 않는다(loadHTMLString, baseURL 없음).
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: config)
        hitView = CharacterHitView(frame: NSRect(origin: .zero, size: Self.size))
        super.init()

        // 투명 창. 그림 바깥은 비쳐 보이고, 그림자는 끈다(투명 영역 모양대로 그림자가 생기면 테두리처럼 보인다).
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // floating: 일반 창보다 위. 다른 앱을 써도 가려지지 않는다. 메뉴·팝오버·알림보다는 아래다.
        panel.level = .floating
        // NSPanel은 기본으로 앱이 비활성일 때 숨는다. 이 앱은 Dock 없는 보조 앱이라 거의 항상 비활성이므로 꺼야 보인다.
        panel.hidesOnDeactivate = false
        // canJoinAllSpaces: 모든 Space(데스크톱)에 보인다. fullScreenAuxiliary: 전체화면 앱의 Space에도 함께 뜬다.
        // stationary: Mission Control·Exposé에서 다른 창처럼 흩어지지 않는다. ignoresCycle: ⌘` 창 순환에서 뺀다.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        // 끌기는 hitView가 직접 처리한다. 배경 끌기를 켜 두면 클릭 판정 전에 창이 먼저 움직인다.
        panel.isMovableByWindowBackground = false
        panel.title = "pytest Menu Helper 캐릭터"

        // WKWebView 배경을 투명하게 한다. 공개 API(underPageBackgroundColor)만으로는 흰 바탕이 남아 KVC를 쓴다.
        // 이 키가 없어지면(향후 macOS) 흰 사각형 위에 캐릭터가 보이게 된다. 그때는 이 줄을 먼저 확인한다.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        hitView.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(webView)
        // hitView를 웹뷰 위에 둔다(나중에 넣은 뷰가 위). 마우스를 모두 여기서 받는다.
        container.addSubview(hitView)
        panel.contentView = container

        hitView.onClick = { [weak self] in
            guard let self = self else { return }
            Self.log.notice("[캐릭터] 클릭 → 팝오버 env=\(self.state.envID ?? "-", privacy: .public)")
            self.onClick(self.hitView, self.state)
        }
        hitView.onMoved = { [weak self] origin in self?.saveOrigin(origin) }

        webView.loadHTMLString(CharacterPage.html(svgs: Self.loadSVGs()), baseURL: nil)
        placeAtSavedOrDefault()
        // 화면 배치가 바뀌면(모니터 연결·해제, 해상도 변경) 창이 화면 밖에 남지 않게 다시 맞춘다.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// 번들의 포즈별 SVG 원문을 읽는다. 읽지 못한 포즈는 빠지고, 페이지는 그 포즈에서 글씨만 보인다.
    private static func loadSVGs() -> [CharacterPose: String] {
        var result: [CharacterPose: String] = [:]
        for pose in CharacterPose.allCases {
            guard let url = Bundle.main.url(forResource: pose.assetName, withExtension: "svg"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                log.error("[캐릭터] 에셋 없음: \(pose.assetName, privacy: .public).svg")
                continue
            }
            result[pose] = text
        }
        return result
    }

    // MARK: 상태

    /// 새 상태를 보여 준다(메인 스레드). 같은 상태면 아무것도 하지 않는다.
    /// - Parameter newState: CharacterPresentation.state의 결과.
    /// 페이지가 아직 로드 중이면 기억만 했다가 로드가 끝나면 넣는다(webView(_:didFinish:)).
    func apply(_ newState: CharacterState) {
        state = newState
        hitView.toolTip = newState.help
        guard pageLoaded, appliedState != newState else { return }
        appliedState = newState
        // 통합 검증용 로그. 상태 전환(대기 → 달리기 → 성공/실패/갸웃)을 화면 없이 확인한다.
        Self.log.notice("[캐릭터] pose=\(newState.pose.rawValue, privacy: .public) label=\(newState.label, privacy: .public) env=\(newState.envID ?? "-", privacy: .public) key=\(newState.key, privacy: .public) help=\(newState.help, privacy: .public)")
        webView.evaluateJavaScript(CharacterPage.script(for: newState)) { _, error in
            if let error = error {
                Self.log.error("[캐릭터] setPose 실패: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        apply(state)
        updateVisibility()
    }

    /// 웹 콘텐츠 프로세스가 죽으면(메모리 압박 등) 빈 창이 남는다. 페이지를 다시 읽어 마지막 상태로 되돌린다.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("[캐릭터] 웹 콘텐츠 프로세스 종료, 페이지를 다시 읽음")
        pageLoaded = false
        appliedState = nil
        webView.loadHTMLString(CharacterPage.html(svgs: Self.loadSVGs()), baseURL: nil)
    }

    // MARK: 보이기·위치

    /// 설정에 맞춰 창을 보이거나 숨긴다. 페이지 로드 전에는 띄우지 않는다(흰 사각형·빈 창이 잠깐 보이지 않게).
    private func updateVisibility() {
        if isVisible && pageLoaded {
            // orderFrontRegardless: 앱이 비활성이어도 앞에 띄운다. orderFront는 비활성 앱에서 무시될 수 있다.
            panel.orderFrontRegardless()
            Self.log.notice("[캐릭터] 창 표시 frame=\(NSStringFromRect(self.panel.frame), privacy: .public) windowNumber=\(self.panel.windowNumber)")
        } else {
            panel.orderOut(nil)
        }
    }

    /// 저장한 위치가 지금 화면 안이면 그 위치(화면 안으로 맞춘 값), 아니면 주 화면 오른쪽 아래.
    private func placeAtSavedOrDefault() {
        let frames = NSScreen.screens.map(\.visibleFrame)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.originXKey) != nil, defaults.object(forKey: Self.originYKey) != nil {
            let saved = CGPoint(x: defaults.double(forKey: Self.originXKey), y: defaults.double(forKey: Self.originYKey))
            if let origin = CharacterPlacement.clamp(origin: saved, size: Self.size, visibleFrames: frames) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        // NSScreen.main은 키 창이 있는 화면이라 보조 앱에서는 엉뚱할 수 있다. screens[0]이 메뉴 막대가 있는 주 화면이다.
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(CharacterPlacement.defaultOrigin(visibleFrame: visible, size: Self.size))
    }

    @objc private func screensChanged() {
        let frames = NSScreen.screens.map(\.visibleFrame)
        if let origin = CharacterPlacement.clamp(origin: panel.frame.origin, size: Self.size, visibleFrames: frames) {
            panel.setFrameOrigin(origin)
        } else {
            placeAtSavedOrDefault()
        }
    }

    /// 끌기가 끝난 위치를 화면 안으로 맞춰 저장한다.
    private func saveOrigin(_ origin: CGPoint) {
        let frames = NSScreen.screens.map(\.visibleFrame)
        let fixed = CharacterPlacement.clamp(origin: origin, size: Self.size, visibleFrames: frames) ?? origin
        if fixed != origin { panel.setFrameOrigin(fixed) }
        UserDefaults.standard.set(Double(fixed.x), forKey: Self.originXKey)
        UserDefaults.standard.set(Double(fixed.y), forKey: Self.originYKey)
        Self.log.notice("[캐릭터] 위치 저장 \(NSStringFromPoint(fixed), privacy: .public)")
    }
}

/// 웹뷰 위에 덮은 투명 뷰. 마우스를 받아 클릭과 창 끌기를 나눈다.
/// 클릭: 누른 뒤 dragThreshold(3pt) 안에서 뗌. 끌기: 그보다 많이 움직임(창을 따라 옮기고, 놓으면 위치 저장).
final class CharacterHitView: NSView {
    var onClick: () -> Void = {}
    var onMoved: (CGPoint) -> Void = { _ in }

    /// 누른 순간의 화면 좌표와 창 위치. 끌기 중 이동량 계산에 쓴다.
    private var downScreenPoint: NSPoint?
    private var downWindowOrigin: NSPoint?
    private var dragging = false

    /// 앱이 비활성일 때 첫 클릭부터 받는다. false면 첫 클릭은 창을 활성화하는 데만 쓰이고 버려진다.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// 투명한 부분까지 이 뷰가 받는다(웹뷰로 넘기지 않는다).
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) {
        downScreenPoint = NSEvent.mouseLocation
        downWindowOrigin = window?.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downScreenPoint, let origin = downWindowOrigin, let window = window else { return }
        // event.locationInWindow 대신 화면 좌표를 쓰는 이유: 창이 마우스를 따라 움직이므로 창 기준 좌표는 계속 바뀐다.
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragging && !CharacterPlacement.isDrag(dx: dx, dy: dy) { return }
        dragging = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { downScreenPoint = nil; downWindowOrigin = nil; dragging = false }
        guard downScreenPoint != nil else { return }
        if dragging {
            if let origin = window?.frame.origin { onMoved(origin) }
        } else {
            onClick()
        }
    }
}
