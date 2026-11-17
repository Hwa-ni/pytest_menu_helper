// AppDelegate.swift
// 메뉴 막대 앱의 본체. 상태 막대 아이콘, 결과 팝오버, 등록 파일 저장, 환경 검사, pytest 실행·중지를 잇는다.
// 입력: 등록 파일(ProjectStore), 환경 검사 결과(EnvironmentChecker), 실행 상태 알림(RunController),
// 팝오버 화면의 사용자 동작(PopoverViewModel의 콜백).
// 출력: 팝오버 화면 상태, 등록 파일 저장, 폴더·파일 선택 창, 클립보드 복사, pytest 실행·중지 요청.
// 아이콘 왼쪽 클릭은 팝오버를 연다. 앱의 모든 동작(프로젝트·환경 추가와 제거, 다시 검사, 설치 명령 복사, 종료)은
// 팝오버 안에 있다(PopoverView.swift). 오른쪽 클릭(또는 control+클릭)은 "종료" 하나만 있는 작은 메뉴다.
// 예전에는 같은 기능을 큰 NSMenu와 팝오버 두 곳에서 관리했는데, 열린 메뉴 갱신 코드가 복잡하고 어긋나기 쉬워
// 팝오버 한 곳으로 모았다.
// 실행 중인 환경과 그 환경이 속한 프로젝트는 제거할 수 없다. 제거하면 팝오버에서 그 행(■ 중지)이 사라지고
// 그 실행이 끝날 때까지 다른 환경의 ▶도 꺼진 채 남기 때문이다. 화면에서 막고, 동작 함수에서도 한 번 더 막는다.

import AppKit
import PMHCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    /// 오른쪽 클릭 메뉴("종료"만). 열 때만 statusItem에 잠깐 건다(showQuitMenu 참고).
    private let quitMenu = NSMenu()
    /// 왼쪽 클릭으로 여는 팝오버. 바깥을 누르면 닫힌다(.transient).
    private let popover = NSPopover()
    /// 팝오버 화면의 상태. 등록·검사·실행 상태가 바뀔 때마다 pushPopoverState로 넣는다.
    private let popoverModel = PopoverViewModel()
    /// 팝오버가 마지막으로 닫힌 시각. 아이콘을 눌러 닫을 때 바로 다시 열리는 것을 막는 데 쓴다(togglePopover 참고).
    private var popoverClosedAt: Date?
    /// 폴더·파일 선택 창이 떠 있는지. 떠 있는 동안 아이콘 클릭으로 팝오버가 겹쳐 열리지 않게 한다.
    private var panelIsOpen = false
    private let store = ProjectStore()
    private var registry = Registry()
    /// 등록 파일 읽기 경고(깨진 파일 등). 팝오버 위쪽에 보인다.
    private var loadWarning: String?
    /// 마지막 저장 실패 문장. 다음 저장이 성공하면 지운다.
    private var saveError: String?
    private var checks: [String: EnvCheck] = [:] // 환경 id → 결과(없으면 검사 중)
    /// 컨트롤러 알림을 받는 직렬 큐. 여기서 메인 런루프의 common 모드로 다시 넘긴다(runStateArrived 참고).
    private let notifyQueue = DispatchQueue(label: "pmh.menu-notify")
    /// pytest 실행 담당. 프로세스·파일 읽기·집계는 컨트롤러의 백그라운드 큐에서 한다.
    /// 변경 알림은 notifyQueue로 받은 뒤 메인 스레드에 넘긴다.
    private lazy var controller = RunController(notifyQueue: notifyQueue) { [weak self] snapshot in
        self?.runStateArrived(snapshot)
    }
    private var runSnapshot = RunSnapshot(active: nil, results: [:])
    private lazy var checker: EnvironmentChecker = {
        let repo = Bundle.main.object(forInfoDictionaryKey: "PMHRepoPath") as? String
        return EnvironmentChecker(repoPath: repo)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuBarImage()
        statusItem.button?.toolTip = "pytest Menu Helper"
        // 왼쪽·오른쪽 클릭을 모두 이 동작으로 받아 statusItemClicked에서 나눈다.
        // sendAction(on:)을 빼면 기본값(왼쪽 버튼만)이라 오른쪽 클릭으로 메뉴를 열 수 없다.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setupQuitMenu()
        setupPopover()

        let outcome = store.load()
        registry = outcome.registry
        loadWarning = outcome.warning
        for project in registry.projects { for env in project.environments { recheck(env) } }
        pushPopoverState()
        // 이전 실행이 남긴 이벤트·로그 파일 중 최신 50개만 남긴다(백그라운드).
        controller.cleanup()
    }

    /// 앱을 끄면 실행 중인 pytest를 끝내고 나서 돌아온다.
    /// 일반 stop()을 쓰면 안 되는 이유: 신호를 백그라운드 큐에 넘기기만 해서, 이 함수가 돌아온 직후
    /// 앱 프로세스가 끝나면 SIGINT가 나가지 못하고 pytest가 남는다.
    /// stopForTermination은 SIGINT를 바로 보내고 최대 2.5초 기다린 뒤, 남아 있으면 SIGKILL한다.
    /// 메인 스레드를 막는 시간은 실행이 없으면 0, 있어도 약 3초 안이다.
    func applicationWillTerminate(_ notification: Notification) {
        controller.stopForTermination()
    }

    // MARK: pytest 실행 상태

    /// 컨트롤러 알림(notifyQueue에서 호출됨)을 메인 스레드로 넘긴다.
    /// DispatchQueue.main 대신 메인 런루프의 common 모드를 쓰는 이유: 팝오버 안의 "⋯" 메뉴나 Picker가 열려 있는 동안
    /// 런루프는 이벤트 추적 모드로 돈다. 기본 모드에만 걸리는 작업은 그 메뉴를 닫을 때까지 미뤄질 수 있다.
    /// common 모드에는 추적 모드와 모달 창 모드가 포함되어, 메뉴나 파일 선택 창이 떠 있어도 처리된다.
    /// notifyQueue가 직렬이라 알림 순서는 그대로 유지된다.
    private func runStateArrived(_ snapshot: RunSnapshot) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.runStateChanged(snapshot)
        }
        // PerformBlock은 런루프를 깨우지 않으므로 직접 깨운다. 빠뜨리면 다음 이벤트(마우스 이동 등)까지 기다린다.
        CFRunLoopWakeUp(main)
    }

    /// 실행 상태를 팝오버에 반영한다(메인 스레드). 바뀐 값만 넣으면 SwiftUI가 열린 팝오버를 그 자리에서 다시 그린다.
    private func runStateChanged(_ snapshot: RunSnapshot) {
        runSnapshot = snapshot
        pushPopoverState()
    }

    // MARK: 팝오버

    /// 팝오버와 그 안의 SwiftUI 화면을 준비하고, 화면의 동작을 앱 동작에 잇는다.
    private func setupPopover() {
        popoverModel.onRun = { [weak self] envID in self?.runPytest(envID: envID) }
        popoverModel.onStop = { [weak self] in self?.controller.stop() }
        popoverModel.onAddProject = { [weak self] in self?.addProject() }
        popoverModel.onChoosePythonFile = { [weak self] in self?.choosePythonFile() }
        popoverModel.onAddEnvironment = { [weak self] projectID, path, name in
            self?.addEnvironment(to: projectID, pythonPath: path, name: name)
        }
        popoverModel.onRemove = { [weak self] target in
            switch target {
            case .project(let id): self?.removeProject(id)
            case .environment(let envID, let projectID): self?.removeEnvironment(envID, from: projectID)
            }
        }
        popoverModel.onRecheckProject = { [weak self] id in self?.recheckProject(id) }
        popoverModel.onRecheckEnvironment = { [weak self] envID in self?.recheckEnvironment(envID) }
        popoverModel.onCopy = { command in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        popoverModel.onQuit = { NSApp.terminate(nil) }
        let hosting = NSHostingController(rootView: PopoverRootView(model: popoverModel))
        // 팝오버 크기를 SwiftUI 내용 크기에 맞춘다. 폼을 열거나 실패 목록을 펼치면 팝오버도 함께 커진다
        // (상한은 화면 쪽 스크롤 영역의 maxHeight).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        pushPopoverState()
    }

    /// 팝오버 화면에 지금 상태를 넣는다(메인 스레드). 등록·검사·실행 상태가 바뀌는 모든 곳에서 부른다.
    private func pushPopoverState() {
        popoverModel.update(registry: registry, checks: checks, snapshot: runSnapshot,
                            notices: [loadWarning, saveError].compactMap { $0 })
    }

    /// 아이콘 클릭. 오른쪽 클릭이나 control+왼쪽 클릭이면 종료 메뉴, 그 밖의 왼쪽 클릭이면 팝오버.
    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showQuitMenu()
        } else {
            togglePopover()
        }
    }

    /// 팝오버를 열거나 닫는다.
    /// 열린 팝오버에서 아이콘을 누르면 .transient 동작이 마우스를 누르는 순간 먼저 닫아 버리고,
    /// 마우스를 뗄 때 이 함수가 불려 다시 열린다. 방금(0.3초 안) 닫혔으면 다시 열지 않아 이 깜빡임을 막는다.
    private func togglePopover() {
        if panelIsOpen { return } // 선택 창이 끝나면 runPanelOutsidePopover가 다시 연다
        if popover.isShown { popover.performClose(nil); return }
        if let closed = popoverClosedAt, Date().timeIntervalSince(closed) < 0.3 { return }
        showPopover(fresh: true)
    }

    /// 팝오버를 아이콘 아래에 연다.
    /// - Parameter fresh: true면 사용자가 새로 연 것으로 보고 선택·폼·제거 확인을 처음 상태로 돌린다.
    ///   false면(파일 선택 창 뒤에 다시 열 때) 하던 상태를 그대로 둔다.
    private func showPopover(fresh: Bool) {
        guard !popover.isShown, let button = statusItem.button else { return }
        if fresh { popoverModel.prepareForFreshOpen() }
        pushPopoverState()
        // Dock 아이콘이 없는 앱(LSUIElement)은 활성화하지 않으면 팝오버 창이 키 창이 되지 못해
        // 이름 칸 입력, 텍스트 선택·복사가 되지 않고 바깥 클릭으로 닫히지 않을 때가 있다.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
    }

    /// 선택 창(NSOpenPanel)을 팝오버 밖에서 띄우고, 끝나면(확인·취소 모두) 팝오버를 다시 연다.
    /// - Parameter body: 선택 창을 띄우고 결과를 처리하는 코드. 메인 스레드에서 동기로(runModal) 끝나야 한다.
    /// 이 방식을 고른 이유: 팝오버는 .transient라 선택 창이 키 창이 되는 순간 저절로 닫힌다.
    /// 창이 떠 있는 동안 behavior를 .applicationDefined로 바꿔 열어 두는 방법도 있지만, 상태 막대 팝오버 창은
    /// 일반 창보다 높은 층에 떠서 선택 창을 가리거나 바깥 클릭에 엉뚱하게 반응할 수 있다. 닫고 다시 여는 쪽은
    /// 4단계까지 메뉴에서 쓰던 runModal 흐름 그대로라 동작이 예측 가능하다. 화면 상태(선택한 프로젝트, 폼 입력값)는
    /// 뷰 모델에 있어 닫혀도 사라지지 않고, showPopover(fresh: false)가 그대로 다시 보여 준다.
    /// 주의: 같은 차례에 runModal을 부르면 버튼 동작 안에서 닫히는 팝오버와 모달이 겹친다. 그래서 먼저 닫고
    /// 다음 차례(DispatchQueue.main.async)에 창을 띄운다.
    private func runPanelOutsidePopover(_ body: @escaping () -> Void) {
        guard !panelIsOpen else { return }
        panelIsOpen = true
        popover.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NSApp.activate(ignoringOtherApps: true)
            body()
            self.panelIsOpen = false
            self.showPopover(fresh: false)
        }
    }

    // MARK: 오른쪽 클릭 메뉴

    /// "종료" 하나만 있는 메뉴를 만든다. 다른 동작은 모두 팝오버에 있다.
    private func setupQuitMenu() {
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quitMenu.addItem(quit)
        quitMenu.delegate = self
    }

    /// 종료 메뉴를 아이콘 아래에 연다. 메뉴를 잠깐 걸고 버튼을 누른 것처럼 한 뒤 바로 뗀다.
    /// statusItem.menu를 고정으로 걸지 않는 이유: 걸어 두면 왼쪽 클릭도 메뉴를 열어 팝오버를 띄울 수 없다.
    /// performClick은 메뉴가 닫힐 때까지 돌아오지 않는다(메뉴 추적). 돌아온 뒤 떼어야 다음 왼쪽 클릭이 다시 팝오버를 연다.
    private func showQuitMenu() {
        if popover.isShown { popover.performClose(nil) }
        guard let button = statusItem.button else { return }
        statusItem.menu = quitMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// performClick이 메뉴 추적 전에 돌아오는 경우에도 메뉴가 남아 왼쪽 클릭을 가로채지 않게 여기서도 뗀다.
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    // MARK: 실행

    /// 팝오버의 ▶. 환경 id로 등록 정보를 찾아 실행한다.
    /// 화면에서 버튼을 꺼 두지만, 화면이 갱신되기 전에 눌렸을 때를 대비해 실행 가능 여부를 여기서도 확인한다.
    /// 등록에서 사라진 환경이거나 실행할 수 없는 환경이면 아무것도 하지 않는다.
    /// 같은 순간에 두 번 눌려도 컨트롤러가 1건만 받아들인다(이미 실행 중이면 무시).
    private func runPytest(envID: String) {
        for project in registry.projects {
            guard let env = project.environments.first(where: { $0.id == envID }) else { continue }
            guard let check = checks[envID], RunEligibility.reason(for: check) == nil else { NSSound.beep(); return }
            _ = controller.start(envID: env.id, pythonPath: env.pythonPath, projectPath: project.path)
            return
        }
    }

    // MARK: 아이콘

    private func menuBarImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "mascot-fox-menubar", withExtension: "svg"),
           let image = NSImage(contentsOf: url), image.isValid {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        if let url = Bundle.main.url(forResource: "mascot-fox-menubar@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url), image.isValid {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        // 두 이미지 파일을 읽지 못하면 시스템 기호로 대신한다.
        let fallback = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "pytest Menu Helper")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    // MARK: 검사

    /// 환경 하나를 백그라운드에서 검사한다. 시작하면 결과를 지워 "검사 중"으로 보인다.
    /// 완료 처리는 DispatchQueue.main으로 온다(EnvironmentChecker.checkAsync). 메인 큐는 common 모드에서 처리되므로
    /// 팝오버 안 메뉴나 선택 창이 떠 있어도 결과가 바로 팝오버에 반영된다.
    private func recheck(_ env: PMHEnvironment) {
        checks[env.id] = nil
        checker.checkAsync(pythonPath: env.pythonPath) { [weak self] result in
            guard let self = self else { return }
            // 검사 도중 제거된 환경이면 결과를 버린다.
            let alive = self.registry.projects.contains { $0.environments.contains { $0.id == env.id } }
            if alive { self.checks[env.id] = result }
            self.pushPopoverState()
        }
    }

    /// 프로젝트의 모든 환경을 다시 검사한다. 없는 id면 아무것도 하지 않는다.
    private func recheckProject(_ id: UUID) {
        guard let project = registry.projects.first(where: { $0.id == id }) else { return }
        project.environments.forEach(recheck)
        pushPopoverState()
    }

    /// 환경 하나를 다시 검사한다. 없는 id면 아무것도 하지 않는다.
    private func recheckEnvironment(_ envID: String) {
        for project in registry.projects {
            if let env = project.environments.first(where: { $0.id == envID }) {
                recheck(env)
                pushPopoverState()
                return
            }
        }
    }

    // MARK: 등록 변경

    /// "+ 프로젝트". 폴더 선택 창을 띄우고, 고른 폴더를 등록한 뒤 그 프로젝트의 환경 추가 폼을 연다.
    /// 이미 등록한 폴더면 새로 등록하지 않고 그 프로젝트로 옮겨 폼만 연다(4단계 메뉴와 같은 동선).
    /// 취소해도 팝오버는 다시 열린다(runPanelOutsidePopover).
    private func addProject() {
        runPanelOutsidePopover { [weak self] in
            guard let self = self else { return }
            let panel = NSOpenPanel()
            panel.title = "프로젝트 폴더 선택"
            panel.message = "pytest를 사용할 프로젝트 폴더를 고르세요. 폴더는 검사만 하며 테스트를 실행하지 않습니다."
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let path = url.path
            let projectID: UUID
            if let existing = self.registry.projects.first(where: { $0.path == path }) {
                projectID = existing.id
            } else {
                let project = Project(path: path)
                self.registry.projects.append(project)
                self.persist()
                self.pushPopoverState()
                projectID = project.id
            }
            self.popoverModel.selectProject(projectID)
            self.popoverModel.openAddForm(for: projectID)
        }
    }

    /// 폼의 "다른 파일 선택...". 숨김 파일을 보이고 ~/.venvs에서 시작한다. 고른 경로를 폼에 넣는다.
    /// 취소하면 폼은 고르기 전 상태 그대로 다시 보인다.
    private func choosePythonFile() {
        runPanelOutsidePopover { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Python 실행 파일 선택"
            panel.message = "예: ~/.venvs/<이름>/bin/python"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            // 가상환경의 bin/python은 숨김 폴더(.venv) 안에 있을 때가 많다.
            panel.showsHiddenFiles = true
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".venvs")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self?.popoverModel.setFormCustomPath(url.path) // 심볼릭 링크를 풀지 않는다(가상환경은 경로가 곧 환경이다)
        }
    }

    /// 환경을 등록하고 검사를 시작한다.
    /// - Parameters: projectID(대상 프로젝트), pythonPath, name(폼이 정리한 이름).
    /// - Returns: 새 환경 id. 프로젝트가 없거나 같은 경로가 이미 있으면 nil(폼이 이유를 보여 준다).
    private func addEnvironment(to projectID: UUID, pythonPath: String, name: String) -> String? {
        guard let pi = registry.projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        // 폼에서 이미 확인하지만, 그사이 등록이 바뀌었을 때를 대비해 한 번 더 본다.
        if registry.projects[pi].environments.contains(where: { $0.pythonPath == pythonPath }) { return nil }
        let env = PMHEnvironment(name: name, pythonPath: pythonPath)
        registry.projects[pi].environments.append(env)
        persist()
        recheck(env)
        pushPopoverState()
        return env.id
    }

    /// 지금 실행 중인 환경 id. 동작 함수의 방어 확인에 쓴다.
    /// 화면용 runSnapshot이 아니라 컨트롤러의 현재 상태를 읽는 이유: 알림이 메인에 닿기 전이라도
    /// 방금 시작된 실행을 놓치지 않기 위함이다.
    private var activeEnvID: String? { controller.snapshot.active?.envID }

    /// 프로젝트 등록을 지운다. 확인은 팝오버의 인라인 확인 상자에서 이미 받았다.
    /// 매개변수 id: 지울 프로젝트 id. 없는 id거나, 그 프로젝트의 환경이 실행 중이면 아무것도 하지 않는다.
    /// 화면에서 [제거]를 꺼 두지만, 화면이 갱신되기 전에 눌렸을 때(방금 실행 시작)를 대비해 여기서도 막는다.
    private func removeProject(_ id: UUID) {
        guard let project = registry.projects.first(where: { $0.id == id }) else { return }
        if ManagementPresentation.projectRemovalBlockedReason(project, activeEnvID: activeEnvID) != nil {
            NSSound.beep(); return
        }
        project.environments.forEach { checks[$0.id] = nil }
        registry.projects.removeAll { $0.id == id }
        persist()
        pushPopoverState()
    }

    /// 환경 등록을 지운다. 확인은 팝오버에서 이미 받았다.
    /// 매개변수 envID·projectID: 지울 환경과 그 프로젝트. 없는 id거나 그 환경이 실행 중이면 아무것도 하지 않는다.
    private func removeEnvironment(_ envID: String, from projectID: UUID) {
        // 화면에서 꺼 두지만, 화면이 갱신되기 전에 눌렸을 때를 대비해 여기서도 막는다.
        if ManagementPresentation.environmentRemovalBlockedReason(envID: envID, activeEnvID: activeEnvID) != nil {
            NSSound.beep(); return
        }
        guard let i = registry.projects.firstIndex(where: { $0.id == projectID }) else { return }
        registry.projects[i].environments.removeAll { $0.id == envID }
        checks[envID] = nil
        persist()
        pushPopoverState()
    }

    /// 등록 파일에 저장한다. 실패하면 경고 창 대신 팝오버 위쪽에 문장을 보인다.
    /// 경고 창(NSAlert)을 쓰지 않는 이유: 창이 뜨면 .transient 팝오버가 닫혀 하던 일이 끊긴다.
    /// 메모리의 등록 정보는 바뀐 채로 두므로(예전과 같음), 다음 변경 때 다시 저장을 시도한다.
    private func persist() {
        do {
            try store.save(registry)
            saveError = nil
        } catch {
            saveError = "등록 정보를 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }
}
