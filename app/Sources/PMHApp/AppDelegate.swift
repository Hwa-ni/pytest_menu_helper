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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = ProjectStore()
    private var registry = Registry()
    private var loadWarning: String?
    private var checks: [String: EnvCheck] = [:] // 환경 id → 결과(없으면 검사 중)
    /// pytest 실행 담당. 프로세스·파일 읽기·집계는 컨트롤러의 백그라운드 큐에서 하고,
    /// 변경 알림만 메인 큐로 받아 메뉴를 갱신한다.
    private lazy var controller = RunController { [weak self] snapshot in self?.runStateChanged(snapshot) }
    private var runSnapshot = RunSnapshot(active: nil, results: [:])
    /// 지금 메뉴에 걸려 있는 진행 줄. 메뉴가 열려 있는 동안 제목만 바꾸려고 기억한다.
    private weak var progressItem: NSMenuItem?
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

    /// 앱을 끄면 실행 중인 pytest에 중지 신호(SIGINT)를 보낸다. 자식이 앱보다 오래 남지 않게 하는 최선의 시도다.
    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    // MARK: pytest 실행 상태

    /// 컨트롤러가 메인 큐로 알려 준 상태를 반영한다.
    /// 진행 숫자만 바뀐 경우에는 열려 있는 메뉴의 줄만 고치고, 시작·종료·중지 같은 구조 변화는 메뉴를 다시 만든다.
    private func runStateChanged(_ snapshot: RunSnapshot) {
        let old = runSnapshot
        runSnapshot = snapshot
        if let a = old.active, let b = snapshot.active, a.runID == b.runID, a.stopping == b.stopping,
           old.results == snapshot.results, let item = progressItem {
            item.title = b.phase.text
            return
        }
        rebuildMenu()
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
        // SVG를 못 읽으면 기본 기호로 대신한다(앱은 계속 동작).
        let fallback = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "pytest Menu Helper")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    // MARK: 메뉴

    private func rebuildMenu() {
        let menu = NSMenu()
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
        sub.addItem(ActionItem("프로젝트 제거") { [weak self] in self?.removeProject(project.id) })
        item.submenu = sub
        return item
    }

    private func environmentItem(_ env: PMHEnvironment, in project: Project) -> NSMenuItem {
        let check = checks[env.id]
        let title: String
        if let check = check {
            let v = check.pythonVersionText.map { "Python \($0)" } ?? "Python -"
            title = "\(env.name) · \(v) · \(check.status.label)"
        } else {
            title = "\(env.name) · 검사 중…"
        }
        let runningHere = runSnapshot.active?.envID == env.id ? runSnapshot.active : nil
        let item = NSMenuItem(title: runningHere.map { "\(title) · \($0.phase.text)" } ?? title,
                              action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // 자동 활성화를 끄지 않으면 "pytest 실행" 같은 항목의 비활성 지정이 무시되어 다시 켜진다.
        sub.autoenablesItems = false
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
        sub.addItem(ActionItem("환경 제거") { [weak self] in self?.removeEnvironment(env.id, from: project.id) })
        item.submenu = sub
        return item
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
                sub.addItem(infoItem("실행 불가: \(reason)"))
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

    private func removeProject(_ id: UUID) {
        guard let project = registry.projects.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(project.name) 등록을 제거할까요?"
        alert.informativeText = "앱의 등록 정보만 지웁니다. 프로젝트 폴더와 Python 환경은 그대로 둡니다."
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        project.environments.forEach { checks[$0.id] = nil }
        registry.projects.removeAll { $0.id == id }
        persist()
        rebuildMenu()
    }

    private func removeEnvironment(_ envID: String, from projectID: UUID) {
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
