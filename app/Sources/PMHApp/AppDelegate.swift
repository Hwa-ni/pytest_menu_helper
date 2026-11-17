// AppDelegate.swift
// 메뉴 막대 앱의 본체. 프로젝트·환경 등록 메뉴를 만들고, pytest 실행 상태를 메뉴에 보여 준다.
// 입력: 등록 파일(ProjectStore), 환경 검사 결과(EnvironmentChecker), 실행 상태 알림(RunController).
// 출력: 상태 막대 메뉴, 등록 파일 저장, pytest 실행·중지 요청.
// 실행 중인 환경과 그 환경이 속한 프로젝트는 제거할 수 없다. 제거하면 메뉴에서 "중지"가 사라지고
// 그 실행이 끝날 때까지 다른 환경의 실행 버튼도 꺼진 채 남기 때문이다.

import AppKit
import PMHCore

/// 클로저를 실행하는 메뉴 항목.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

func infoItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = ProjectStore()
    private var registry = Registry()
    private var loadWarning: String?
    private var checks: [String: EnvCheck] = [:] // 환경 id → 결과(없으면 검사 중)
    /// 컨트롤러 알림을 받는 직렬 큐. 여기서 메인 런루프의 common 모드로 다시 넘긴다(runStateArrived 참고).
    private let notifyQueue = DispatchQueue(label: "pmh.menu-notify")
    /// pytest 실행 담당. 프로세스·파일 읽기·집계는 컨트롤러의 백그라운드 큐에서 한다.
    /// 변경 알림은 notifyQueue로 받은 뒤 메뉴가 열려 있어도 처리되는 방식으로 메인 스레드에 넘긴다.
    private lazy var controller = RunController(notifyQueue: notifyQueue) { [weak self] snapshot in
        self?.runStateArrived(snapshot)
    }
    private var runSnapshot = RunSnapshot(active: nil, results: [:])
    /// 지금 메뉴에 걸려 있는 진행 줄. 메뉴가 열려 있는 동안 제목만 바꾸려고 기억한다.
    private weak var progressItem: NSMenuItem?

    /// 환경 하나의 메뉴 항목과 하위 메뉴. 실행 상태가 바뀌면 메뉴를 새로 만들지 않고 이 항목들을 그 자리에서 고친다.
    /// 새로 만들면 안 되는 이유: 사용자가 보고 있는 열린 메뉴는 예전 객체라서, statusItem.menu를 바꿔 끼워도
    /// 화면에는 반영되지 않는다. 그래서 끝난 실행이 계속 "실행 중"으로 보였다.
    private struct EnvMenu {
        let item: NSMenuItem
        let sub: NSMenu
        let env: PMHEnvironment
        let project: Project
    }
    /// 환경 id → 지금 메뉴에 걸린 항목. rebuildMenu가 매번 새로 채운다.
    private var envMenus: [String: EnvMenu] = [:]

    /// 프로젝트 하위 메뉴의 "프로젝트 제거" 항목과 그 아래 이유 줄.
    /// 실행 상태가 바뀌면 메뉴를 다시 만들지 않고 이 두 항목의 켜짐·숨김만 고친다(열린 메뉴에도 보이도록).
    private struct ProjectMenu {
        let removeItem: NSMenuItem
        let reasonItem: NSMenuItem
        let project: Project
    }
    /// 프로젝트 id → 지금 메뉴에 걸린 제거 항목. rebuildMenu가 매번 새로 채운다.
    private var projectMenus: [UUID: ProjectMenu] = [:]
    /// 실행 중이라 제거를 막을 때 보여 주는 이유 문장.
    private static let removeBlockedReason = "실행 중에는 제거할 수 없습니다. 먼저 중지하세요."
    /// 메뉴가 열려 있는지. 열려 있는 동안에는 메뉴 전체를 바꿔 끼우지 않는다.
    private var menuIsOpen = false
    /// 메뉴가 열려 있어 미뤄 둔 전체 다시 만들기가 있는지. 메뉴가 닫히면 처리한다.
    private var rebuildPending = false
    private lazy var checker: EnvironmentChecker = {
        let repo = Bundle.main.object(forInfoDictionaryKey: "PMHRepoPath") as? String
        return EnvironmentChecker(repoPath: repo)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuBarImage()
        statusItem.button?.toolTip = "pytest Menu Helper"

        let outcome = store.load()
        registry = outcome.registry
        loadWarning = outcome.warning
        for project in registry.projects { for env in project.environments { recheck(env) } }
        rebuildMenu()
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
    /// DispatchQueue.main 대신 메인 런루프의 common 모드를 쓰는 이유: 메뉴가 열려 있는 동안 런루프는
    /// 이벤트 추적 모드로 돌기 때문에, 기본 모드에만 걸리는 작업은 메뉴를 닫을 때까지 미뤄질 수 있다.
    /// common 모드에는 추적 모드가 포함되어 메뉴가 열린 채로도 처리된다.
    /// notifyQueue가 직렬이라 알림 순서는 그대로 유지된다.
    private func runStateArrived(_ snapshot: RunSnapshot) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.runStateChanged(snapshot)
        }
        // PerformBlock은 런루프를 깨우지 않으므로 직접 깨운다. 빠뜨리면 다음 이벤트(마우스 이동 등)까지 기다린다.
        CFRunLoopWakeUp(main)
    }

    /// 실행 상태를 메뉴에 반영한다(메인 스레드).
    /// 진행 숫자만 바뀐 경우에는 진행 줄과 환경 제목만 고치고, 시작·종료·중지 같은 변화는
    /// 각 환경 하위 메뉴의 내용을 그 자리에서 다시 채운다. 메뉴 전체를 바꿔 끼우지 않으므로 열린 메뉴에도 바로 보인다.
    private func runStateChanged(_ snapshot: RunSnapshot) {
        let old = runSnapshot
        runSnapshot = snapshot
        if let a = old.active, let b = snapshot.active, a.runID == b.runID, a.stopping == b.stopping,
           old.results == snapshot.results, let item = progressItem {
            item.title = b.phase.text
            if let ref = envMenus[b.envID] { ref.item.title = environmentTitle(ref.env) }
            return
        }
        refreshRunSections()
    }

    /// 모든 환경 항목의 제목과 하위 메뉴 내용을 지금 상태로 다시 채운다(메뉴 객체는 그대로 둔다).
    /// 프로젝트 하위 메뉴의 "프로젝트 제거" 항목도 함께 고친다. 실행이 끝나면 여기서 다시 켜진다.
    private func refreshRunSections() {
        progressItem = nil // 새로 채우는 진행 줄이 다시 지정한다. 지우지 않으면 사라진 줄을 계속 고친다.
        for ref in envMenus.values {
            ref.item.title = environmentTitle(ref.env)
            ref.sub.removeAllItems()
            fillEnvironmentMenu(ref.sub, env: ref.env, project: ref.project)
        }
        for ref in projectMenus.values { updateProjectRemoveItems(ref) }
    }

    /// 실행 중인 환경이 이 프로젝트에 있는지. 메뉴 표시에 쓰므로 메뉴가 아는 상태(runSnapshot)로 판단한다.
    private func projectHasActiveRun(_ project: Project) -> Bool {
        guard let active = runSnapshot.active else { return false }
        return project.environments.contains { $0.id == active.envID }
    }

    /// "프로젝트 제거" 항목을 실행 상태에 맞춘다. 실행 중이면 끄고 이유 줄을 보이고, 아니면 켜고 이유 줄을 숨긴다.
    /// 이유 줄을 지웠다 넣지 않고 숨기는 이유: 열린 메뉴에서 항목 순서를 바꾸지 않고 그 자리에서 바꾸기 위함이다.
    private func updateProjectRemoveItems(_ ref: ProjectMenu) {
        let blocked = projectHasActiveRun(ref.project)
        ref.removeItem.isEnabled = !blocked
        ref.reasonItem.isHidden = !blocked
    }

    // MARK: NSMenuDelegate (최상위 메뉴만)

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    /// 메뉴가 닫히면 열려 있는 동안 미뤄 둔 전체 다시 만들기를 한다.
    /// 메뉴 항목의 동작(예: 다시 검사)이 닫힘보다 먼저 오든 나중에 오든, 이 처리로 결국 한 번은 반영된다.
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if rebuildPending {
            rebuildPending = false
            rebuildMenu()
        }
    }

    /// 실행 버튼. 같은 순간에 두 번 눌려도 컨트롤러가 1건만 받아들인다(이미 실행 중이면 무시).
    private func runPytest(_ env: PMHEnvironment, in project: Project) {
        _ = controller.start(envID: env.id, pythonPath: env.pythonPath, projectPath: project.path)
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

    // MARK: 메뉴

    /// 메뉴 전체를 새로 만들어 상태 아이콘에 건다.
    /// 메뉴가 열려 있으면 바꿔 끼워도 화면에 보이지 않으므로, 실행 영역만 그 자리에서 고치고 전체는 닫힐 때로 미룬다.
    private func rebuildMenu() {
        if menuIsOpen {
            rebuildPending = true
            refreshRunSections()
            return
        }
        envMenus = [:]
        projectMenus = [:]
        progressItem = nil
        let menu = NSMenu()
        menu.delegate = self
        if let w = loadWarning {
            menu.addItem(infoItem("⚠︎ " + w))
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("프로젝트 추가...") { [weak self] in self?.addProject() })
        if !registry.projects.isEmpty { menu.addItem(.separator()) }
        for project in registry.projects { menu.addItem(projectItem(project)) }
        menu.addItem(.separator())
        menu.addItem(ActionItem("종료") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }

    private func projectItem(_ project: Project) -> NSMenuItem {
        let summary = ProjectSummary.summarize(project.environments.map { checks[$0.id] })
        let item = NSMenuItem(title: "\(project.name) — \(summary.label)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // 자동 활성화를 끄지 않으면 "프로젝트 제거"의 비활성 지정이 무시되어 실행 중에도 켜진다.
        sub.autoenablesItems = false
        sub.addItem(infoItem(project.path))
        sub.addItem(.separator())
        if project.environments.isEmpty {
            sub.addItem(infoItem("환경이 없습니다. '환경 추가'로 등록하세요."))
        }
        for env in project.environments { sub.addItem(environmentItem(env, in: project)) }
        sub.addItem(.separator())
        sub.addItem(ActionItem("환경 추가...") { [weak self] in self?.addEnvironment(to: project.id) })
        sub.addItem(ActionItem("환경 다시 검사") { [weak self] in
            project.environments.forEach { self?.recheck($0) }
            self?.rebuildMenu()
        })
        sub.addItem(.separator())
        let remove = ActionItem("프로젝트 제거") { [weak self] in self?.removeProject(project.id) }
        let reason = infoItem(Self.removeBlockedReason)
        sub.addItem(remove)
        sub.addItem(reason)
        let ref = ProjectMenu(removeItem: remove, reasonItem: reason, project: project)
        updateProjectRemoveItems(ref)
        projectMenus[project.id] = ref
        item.submenu = sub
        return item
    }

    /// 환경 항목 제목: 이름 · Python 버전 · 검사 상태, 실행 중이면 진행 상태를 덧붙인다.
    private func environmentTitle(_ env: PMHEnvironment) -> String {
        let title: String
        if let check = checks[env.id] {
            let v = check.pythonVersionText.map { "Python \($0)" } ?? "Python -"
            title = "\(env.name) · \(v) · \(check.status.label)"
        } else {
            title = "\(env.name) · 검사 중…"
        }
        guard let active = runSnapshot.active, active.envID == env.id else { return title }
        return "\(title) · \(active.phase.text)"
    }

    /// 환경 항목과 하위 메뉴를 만들고, 실행 상태가 바뀔 때 고칠 수 있게 envMenus에 기억한다.
    private func environmentItem(_ env: PMHEnvironment, in project: Project) -> NSMenuItem {
        let item = NSMenuItem(title: environmentTitle(env), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // 자동 활성화를 끄지 않으면 "pytest 실행" 같은 항목의 비활성 지정이 무시되어 다시 켜진다.
        sub.autoenablesItems = false
        fillEnvironmentMenu(sub, env: env, project: project)
        item.submenu = sub
        envMenus[env.id] = EnvMenu(item: item, sub: sub, env: env, project: project)
        return item
    }

    /// 환경 하위 메뉴의 내용을 채운다. 처음 만들 때와 실행 상태가 바뀔 때(비운 뒤) 모두 이 함수를 쓴다.
    /// 매개변수 sub: 비어 있는 하위 메뉴. env·project: 이 메뉴가 가리키는 환경과 그 프로젝트.
    private func fillEnvironmentMenu(_ sub: NSMenu, env: PMHEnvironment, project: Project) {
        let check = checks[env.id]
        let runningHere = runSnapshot.active?.envID == env.id ? runSnapshot.active : nil
        sub.addItem(infoItem(env.pythonPath))
        if let report = check?.report {
            let pluginText = report.pluginInstalled ? "설치됨 \(report.pluginVersion ?? "(버전 불명)")" : "없음"
            sub.addItem(infoItem("pytest \(report.pytestVersion ?? "없음") · FastAPI \(report.fastapiVersion ?? "없음") · 플러그인 \(pluginText)"))
        }
        addRunSection(to: sub, env: env, project: project, check: check, runningHere: runningHere)
        for issue in check?.issues ?? [] {
            sub.addItem(.separator())
            sub.addItem(infoItem("\(issue.severity.label): \(issue.message)"))
            if let command = issue.fixCommand {
                sub.addItem(ActionItem("설치 명령 복사: \(command)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                })
            }
        }
        sub.addItem(.separator())
        sub.addItem(ActionItem("이 환경 다시 검사") { [weak self] in
            self?.recheck(env)
            self?.rebuildMenu()
        })
        // 실행 중인 환경은 제거를 막는다. 제거하면 envMenus에서 빠져 "중지" 버튼에 닿을 수 없게 된다.
        // 이 함수는 실행 상태가 바뀔 때마다 다시 불리므로(refreshRunSections), 실행이 끝나면 다시 켜진다.
        sub.addItem(ActionItem("환경 제거", enabled: runningHere == nil) { [weak self] in
            self?.removeEnvironment(env.id, from: project.id)
        })
        if runningHere != nil { sub.addItem(infoItem(Self.removeBlockedReason)) }
    }

    /// 환경 하위 메뉴의 실행 영역: 실행/중지 버튼, 진행 줄, 마지막 결과 줄.
    /// 실행 버튼은 앱 전체에서 실행이 없고 환경 검사가 통과했을 때만 켠다(실행 불가 이유는 줄로 보여 준다).
    private func addRunSection(to sub: NSMenu, env: PMHEnvironment, project: Project,
                               check: EnvCheck?, runningHere: ActiveRun?) {
        sub.addItem(.separator())
        if let active = runningHere {
            let line = infoItem(active.stopping ? "중지하는 중… (\(active.phase.text))" : active.phase.text)
            progressItem = active.stopping ? nil : line
            sub.addItem(line)
            sub.addItem(ActionItem("중지", enabled: !active.stopping) { [weak self] in self?.controller.stop() })
        } else {
            let reason = RunEligibility.reason(for: check)
            let busy = runSnapshot.active != nil
            sub.addItem(ActionItem("pytest 실행", enabled: reason == nil && !busy) { [weak self] in
                self?.runPytest(env, in: project)
            })
            if let reason = reason {
                // 이유가 아래 문제 목록(조치 필요·오류 줄)과 같은 문장이면 두 번 보이지 않게 짧게 가리킨다.
                // 목록에 없는 이유(검사 중 등)는 그대로 보여 준다. 빠뜨리면 실행이 왜 막혔는지 알 수 없다.
                let listedBelow = check?.issues.contains { reason.contains($0.message) } ?? false
                sub.addItem(infoItem(listedBelow ? "실행 불가: 아래 문제를 먼저 해결하세요." : "실행 불가: \(reason)"))
            } else if busy {
                sub.addItem(infoItem("다른 환경의 실행이 끝날 때까지 기다리세요(동시에 1건만 실행)."))
            }
        }
        if let outcome = runSnapshot.results[env.id] {
            sub.addItem(infoItem("마지막 결과: \(outcome.title)"))
            if let detail = outcome.detail { sub.addItem(infoItem(detail)) }
        }
    }

    // MARK: 동작

    private func recheck(_ env: PMHEnvironment) {
        checks[env.id] = nil
        checker.checkAsync(pythonPath: env.pythonPath) { [weak self] result in
            guard let self = self else { return }
            // 검사 도중 제거된 환경이면 결과를 버린다.
            let alive = self.registry.projects.contains { $0.environments.contains { $0.id == env.id } }
            if alive { self.checks[env.id] = result }
            self.rebuildMenu()
        }
    }

    private func addProject() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "프로젝트 폴더 선택"
        panel.message = "pytest를 사용할 프로젝트 폴더를 고르세요. 폴더는 검사만 하며 테스트를 실행하지 않습니다."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if let existing = registry.projects.first(where: { $0.path == path }) {
            addEnvironment(to: existing.id)
            return
        }
        let project = Project(path: path)
        registry.projects.append(project)
        persist()
        rebuildMenu()
        addEnvironment(to: project.id)
    }

    /// 지금 실행 중인 환경 id. 동작 함수의 방어 확인에 쓴다.
    /// 메뉴용 runSnapshot이 아니라 컨트롤러의 현재 상태를 읽는 이유: 알림이 메인에 닿기 전이라도
    /// 방금 시작된 실행을 놓치지 않기 위함이다.
    private var activeEnvID: String? { controller.snapshot.active?.envID }

    /// 프로젝트 등록을 지운다(확인 창을 거친다).
    /// 매개변수 id: 지울 프로젝트 id. 없는 id거나, 그 프로젝트의 환경이 실행 중이면 아무것도 하지 않는다.
    private func removeProject(_ id: UUID) {
        guard let project = registry.projects.first(where: { $0.id == id }) else { return }
        // 메뉴에서 꺼 두지만, 메뉴가 갱신되기 전에 눌렸을 때를 대비해 여기서도 막는다.
        let isRunning = { [weak self] in
            guard let envID = self?.activeEnvID else { return false }
            return project.environments.contains { $0.id == envID }
        }
        if isRunning() { NSSound.beep(); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(project.name) 등록을 제거할까요?"
        alert.informativeText = "앱의 등록 정보만 지웁니다. 프로젝트 폴더와 Python 환경은 그대로 둡니다."
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // 확인 창이 떠 있는 동안 실행이 시작됐을 수 있어 한 번 더 확인한다.
        if isRunning() { NSSound.beep(); return }
        project.environments.forEach { checks[$0.id] = nil }
        registry.projects.removeAll { $0.id == id }
        persist()
        rebuildMenu()
    }

    /// 환경 등록을 지운다.
    /// 매개변수 envID·projectID: 지울 환경과 그 프로젝트. 없는 id거나 그 환경이 실행 중이면 아무것도 하지 않는다.
    private func removeEnvironment(_ envID: String, from projectID: UUID) {
        // 메뉴에서 꺼 두지만, 메뉴가 갱신되기 전에 눌렸을 때를 대비해 여기서도 막는다.
        if activeEnvID == envID { NSSound.beep(); return }
        guard let i = registry.projects.firstIndex(where: { $0.id == projectID }) else { return }
        registry.projects[i].environments.removeAll { $0.id == envID }
        checks[envID] = nil
        persist()
        rebuildMenu()
    }

    private func addEnvironment(to projectID: UUID) {
        guard let pi = registry.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = registry.projects[pi]
        let registered = Set(project.environments.map(\.pythonPath))
        let candidates = PythonCandidates.find(projectPath: project.path).filter { !registered.contains($0.path) }

        NSApp.activate(ignoringOtherApps: true)
        let form = EnvironmentForm(candidates: candidates)
        let alert = NSAlert()
        alert.messageText = "\(project.name)에 환경 추가"
        alert.informativeText = "사용할 Python을 고르세요. 앱은 선택한 Python으로 정보를 읽기만 하고 환경을 바꾸지 않습니다."
        alert.accessoryView = form.view
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pythonPath: String
        if let candidate = form.selectedCandidate {
            pythonPath = candidate.path
        } else {
            let panel = NSOpenPanel()
            panel.title = "Python 실행 파일 선택"
            panel.message = "예: ~/.venvs/<이름>/bin/python"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.showsHiddenFiles = true
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".venvs")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            pythonPath = url.path // 심볼릭 링크를 풀지 않는다(가상환경은 경로가 곧 환경이다).
        }
        if registered.contains(pythonPath) { return }
        let typed = form.name.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? defaultEnvironmentName(forPython: pythonPath) : typed
        let env = PMHEnvironment(name: name, pythonPath: pythonPath)
        registry.projects[pi].environments.append(env)
        persist()
        recheck(env)
        rebuildMenu()
    }

    private func persist() {
        do { try store.save(registry) } catch {
            let alert = NSAlert()
            alert.messageText = "등록 정보를 저장하지 못했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// "환경 추가" 창 안의 입력 폼: 후보 목록 + "다른 파일 선택..." + 이름.
final class EnvironmentForm: NSObject {
    let view = NSStackView()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let candidates: [PythonCandidate]
    private var lastAutoName = ""

    init(candidates: [PythonCandidate]) {
        self.candidates = candidates
        super.init()
        for c in candidates { popup.addItem(withTitle: "\(c.label)  (\(c.path))") }
        popup.addItem(withTitle: "다른 파일 선택...")
        popup.target = self
        popup.action = #selector(selectionChanged)
        nameField.placeholderString = "환경 이름"
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.addArrangedSubview(popup)
        view.addArrangedSubview(nameField)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 56)
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        selectionChanged()
    }

    var selectedCandidate: PythonCandidate? {
        let i = popup.indexOfSelectedItem
        return i >= 0 && i < candidates.count ? candidates[i] : nil
    }
    var name: String { nameField.stringValue }

    @objc private func selectionChanged() {
        // 사용자가 이름을 직접 고치지 않았을 때만 자동 이름을 갈아 끼운다.
        let auto = selectedCandidate.map { defaultEnvironmentName(forPython: $0.path) } ?? ""
        if nameField.stringValue.isEmpty || nameField.stringValue == lastAutoName {
            nameField.stringValue = auto
        }
        lastAutoName = auto
    }
}
