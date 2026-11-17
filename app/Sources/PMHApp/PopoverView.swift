// PopoverView.swift
// 메뉴 막대 아이콘을 왼쪽 클릭하면 열리는 팝오버의 SwiftUI 화면. 앱의 모든 동작이 이 화면 안에 있다
// (결과 목록과 실패 상세, 프로젝트·환경 추가와 제거, 다시 검사, 설치 명령 복사, 캐릭터 보이기, 종료).
// 입력: PopoverViewModel이 들고 있는 PopoverState(PMHCore의 ResultPresentation이 만든 값)와
// 화면 안 상태(환경 추가 폼, 제거 확인, 펼친 실패 항목, 알림 문장).
// 출력: 사용자 동작을 뷰 모델의 콜백으로 넘긴다. 등록 파일 저장·검사·파일 선택 창은 AppDelegate가 한다.
// 이 파일은 그리기만 한다. 문구·건수·링 값·실패 목록·기본 선택·제거 가능 여부·폼 자동 이름 규칙은 모두
// PMHCore(ResultPresentation, ManagementPresentation)에서 정하고 단위 테스트로 고정했다.
// 색은 시스템 색(NSColor.system*)과 .secondary만 써서 다크·라이트 모드 모두 시스템이 대비를 맞추게 한다.
// 주의: SwiftUI의 @State는 이 SDK에서 매크로로 구현되어 있고, Command Line Tools에는 그 매크로 플러그인
// (SwiftUIMacros)이 없어 컴파일되지 않는다. 그래서 화면 안의 상태(폼 입력값, 제거 확인, 펼친 실패 항목)도
// 뷰 모델의 @Published에 둔다. @Published·@ObservedObject는 매크로가 아니라 속성 래퍼라 문제없다.
// 이 방식의 덤: 파일 선택 창 때문에 팝오버가 닫혔다 다시 열려도 화면 상태가 뷰 모델에 남아 그대로 이어진다.

import AppKit
import PMHCore
import SwiftUI

/// 팝오버 화면의 상태와 동작을 잇는 뷰 모델. 메인 스레드에서만 쓴다.
/// AppDelegate가 등록 정보·검사 결과·실행 상태가 바뀔 때마다 update를 부르고,
/// 화면은 @Published 값이 바뀌면 다시 그린다. 그래서 팝오버가 열린 채로도 실행 상태·검사 결과·등록 변경이 바로 보인다.
final class PopoverViewModel: ObservableObject {
    /// 화면이 그릴 값. 같은 값이면 다시 넣지 않아 불필요한 다시 그리기를 막는다.
    @Published private(set) var state = PopoverState.empty
    /// 펼친 실패 항목. "환경 id|항목 id"로 기억해, 환경을 바꿨을 때 다른 환경의 같은 id 항목이 펼쳐지지 않게 한다.
    /// 실행이 다시 끝나도 같은 테스트가 또 실패하면 펼친 채로 남는다(같은 id).
    @Published private(set) var expandedFailures: Set<String> = []
    /// 열려 있는 "환경 추가" 폼. nil이면 "+ 환경 추가" 버튼만 보인다.
    @Published private(set) var form: EnvironmentFormState?
    /// 떠 있는 제거 확인 상자의 내용. 상태가 바뀔 때마다 removalTarget으로 다시 만든다(실행이 시작되면 [제거]가 꺼진다).
    @Published private(set) var removal: RemovalConfirmation?
    /// 팝오버 위쪽에 보여 줄 경고 문장(등록 파일 읽기 경고, 저장 실패).
    @Published private(set) var notices: [String] = []
    /// 방금 복사한 명령. 버튼 글자를 잠깐 "복사됨"으로 바꾸는 데 쓴다.
    @Published private(set) var copiedCommand: String?
    /// 캐릭터 창을 보이는지(7단계). 맨 아래 [캐릭터 보이기] 체크 상자에 쓴다. 저장은 AppDelegate(onToggleCharacter)가 한다.
    @Published private(set) var characterVisible = true

    /// 실행(▶) 요청. 매개변수는 환경 id.
    var onRun: (String) -> Void = { _ in }
    /// 중지(■) 요청. 동시에 1건만 실행되므로 대상 환경을 따로 넘기지 않는다.
    var onStop: () -> Void = {}
    /// "+ 프로젝트"·"프로젝트 추가". 폴더 선택 창을 여는 일은 AppDelegate가 한다.
    var onAddProject: () -> Void = {}
    /// 폼의 "다른 파일 선택...". 고른 경로는 AppDelegate가 setFormCustomPath로 돌려준다.
    var onChoosePythonFile: () -> Void = {}
    /// 환경 등록 요청. 매개변수: 프로젝트 id, Python 경로, 이름. 반환: 새 환경 id(등록하지 못했으면 nil).
    var onAddEnvironment: (UUID, String, String) -> String? = { _, _, _ in nil }
    /// 제거 확인 상자의 [제거]. 실행 중이면 AppDelegate가 한 번 더 막는다.
    var onRemove: (RemovalTarget) -> Void = { _ in }
    /// 프로젝트의 모든 환경 다시 검사. 매개변수는 프로젝트 id.
    var onRecheckProject: (UUID) -> Void = { _ in }
    /// 환경 하나 다시 검사. 매개변수는 환경 id.
    var onRecheckEnvironment: (String) -> Void = { _ in }
    /// 설치 명령을 클립보드에 넣는다. 앱은 명령을 실행하지 않는다.
    var onCopy: (String) -> Void = { _ in }
    /// [종료].
    var onQuit: () -> Void = {}
    /// [캐릭터 보이기] 체크 상자. 매개변수는 새 값. 창을 보이거나 숨기고 설정을 저장하는 일은 AppDelegate가 한다.
    var onToggleCharacter: (Bool) -> Void = { _ in }

    private var registry = Registry()
    private var checks: [String: EnvCheck] = [:]
    private var snapshot = RunSnapshot()
    /// 사용자가 고른 프로젝트·환경. nil이면 기본 선택(실행 중인 환경, 없으면 첫 환경)을 쓴다.
    private var preferredProjectID: UUID?
    private var preferredEnvID: String?
    /// 제거 확인 중인 대상. removal은 이 값으로 매번 다시 만든다.
    private var removalTarget: RemovalTarget?

    /// 입력을 바꾸고 화면 값을 다시 만든다.
    /// - Parameters:
    ///   - registry·checks·snapshot: 등록 정보, 환경 id별 검사 결과, 실행 상태.
    ///   - notices: 팝오버 위쪽 경고 문장들.
    func update(registry: Registry, checks: [String: EnvCheck], snapshot: RunSnapshot, notices: [String]) {
        self.registry = registry; self.checks = checks; self.snapshot = snapshot
        if notices != self.notices { self.notices = notices }
        recompute()
    }

    /// 사용자가 아이콘을 눌러 새로 열 때 부른다. 지난번 선택·폼·제거 확인을 지우고 기본 선택(실행 중인 환경)부터 보여 준다.
    /// 파일 선택 창 뒤에 다시 열 때는 부르지 않는다(이어서 하던 상태를 남기기 위함, AppDelegate.runPanelOutsidePopover).
    func prepareForFreshOpen() {
        preferredProjectID = nil; preferredEnvID = nil
        form = nil
        removalTarget = nil
        recompute()
    }

    /// 캐릭터를 눌러 열 때 부른다. 캐릭터가 따르던 환경과 그 프로젝트를 골라 상세에 바로 보여 준다.
    /// 매개변수 envID: 캐릭터가 따르는 환경 id. nil이거나 등록에 없으면 기본 선택(prepareForFreshOpen 결과)을 그대로 둔다.
    func focusEnvironment(_ envID: String?) {
        guard let envID = envID,
              let project = registry.projects.first(where: { p in p.environments.contains { $0.id == envID } }) else { return }
        preferredProjectID = project.id
        preferredEnvID = envID
        recompute()
    }

    /// 캐릭터 보이기 값을 화면에 반영한다(AppDelegate가 저장한 값을 넣는다). 같은 값이면 다시 그리지 않는다.
    func setCharacterVisible(_ visible: Bool) {
        if characterVisible != visible { characterVisible = visible }
    }

    /// 프로젝트를 바꾸면 환경 선택은 새 프로젝트의 기본값으로 돌린다(다른 프로젝트의 환경 id가 남지 않게).
    /// 다른 프로젝트의 폼과 제거 확인도 닫는다. 남겨 두면 화면에 보이지 않는 프로젝트에 환경이 추가될 수 있다.
    func selectProject(_ id: UUID?) {
        preferredProjectID = id; preferredEnvID = nil
        if form?.projectID != id { form = nil }
        removalTarget = nil
        recompute()
    }

    /// 실패 항목을 펼치거나 접는다. 매개변수 key: "환경 id|항목 id".
    func toggleFailure(_ key: String) {
        if expandedFailures.contains(key) { expandedFailures.remove(key) } else { expandedFailures.insert(key) }
    }

    func selectEnvironment(_ id: String) {
        // 지금 보이는 프로젝트를 고정한다. 고정하지 않으면 실행이 끝나 기본 프로젝트가 바뀔 때 화면이 튄다.
        preferredProjectID = state.selectedProjectID
        preferredEnvID = id
        recompute()
    }

    /// ▶를 누르면 그 환경을 선택하고 실행을 요청한다. 선택을 먼저 하는 이유: 실행 중 진행이 바로 상세에 보이게 하려는 것이다.
    func run(_ envID: String) {
        selectEnvironment(envID)
        onRun(envID)
    }

    // MARK: 환경 추가 폼

    /// 폼을 연다. 후보는 이 프로젝트의 .venv와 ~/.venvs에서 찾고(파일 존재만 확인), 이미 등록한 경로는 뺀다.
    /// - Parameter projectID: 대상 프로젝트. nil이면 지금 보이는 프로젝트. 등록에 없는 id면 아무것도 하지 않는다.
    func openAddForm(for projectID: UUID? = nil) {
        guard let id = projectID ?? state.selectedProjectID,
              let project = registry.projects.first(where: { $0.id == id }) else { return }
        let registered = Set(project.environments.map(\.pythonPath))
        let candidates = PythonCandidates.find(projectPath: project.path).filter { !registered.contains($0.path) }
        form = EnvironmentFormState(projectID: id, candidates: candidates)
        removalTarget = nil
        recompute()
    }

    func chooseFormPython(_ choice: PythonChoice?) { form?.choose(choice) }
    func editFormName(_ text: String) { form?.editName(text) }
    /// 파일 선택 창에서 고른 경로를 폼에 넣는다. 그사이 폼이 닫혔으면(프로젝트 제거 등) 버린다.
    func setFormCustomPath(_ path: String) { form?.setCustomPath(path) }
    func cancelForm() { form = nil }

    /// [추가]. 막히면 이유를 폼 아래에 보이고, 등록되면 폼을 닫고 새 환경을 선택한다.
    /// 중복 판정은 폼을 연 시점이 아니라 지금 등록 정보로 한다(그사이 같은 경로가 추가됐을 수 있다).
    func submitForm() {
        guard var current = form else { return }
        guard let project = registry.projects.first(where: { $0.id == current.projectID }) else { form = nil; return }
        switch current.submission(registeredPaths: Set(project.environments.map(\.pythonPath))) {
        case .invalid(let message):
            current.error = message
            form = current
        case .ready(let path, let name):
            guard let newID = onAddEnvironment(project.id, path, name) else {
                current.error = "등록하지 못했습니다. 이미 등록한 경로인지 확인하세요."
                form = current
                return
            }
            form = nil
            preferredProjectID = project.id
            preferredEnvID = newID
            recompute()
        }
    }

    // MARK: 제거 확인

    /// 제거 확인 상자를 띄운다. 실제 제거는 confirmRemoval에서만 한다.
    func requestRemoval(_ target: RemovalTarget) {
        removalTarget = target
        recompute()
    }

    func cancelRemoval() {
        removalTarget = nil
        recompute()
    }

    /// [제거]. 화면에서 꺼져 있어도(실행 중) 눌린 경우를 대비해 canConfirm을 다시 본다.
    func confirmRemoval() {
        guard let confirmation = removal, confirmation.canConfirm else { NSSound.beep(); return }
        removalTarget = nil
        onRemove(confirmation.target)
        recompute()
    }

    // MARK: 복사

    /// 명령을 복사하고 버튼 글자를 1.5초 동안 "복사됨"으로 바꾼다.
    func copy(_ command: String) {
        onCopy(command)
        copiedCommand = command
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            // 그사이 다른 명령을 복사했으면 그 표시는 지우지 않는다.
            if self?.copiedCommand == command { self?.copiedCommand = nil }
        }
    }

    private func recompute() {
        let next = ResultPresentation.build(registry: registry, checks: checks, snapshot: snapshot,
                                            preferredProjectID: preferredProjectID, preferredEnvID: preferredEnvID)
        if next != state { state = next }
        // 폼의 프로젝트가 등록에서 사라졌으면 폼을 닫는다. 남기면 [추가]가 없는 프로젝트를 가리킨다.
        if let f = form, !registry.projects.contains(where: { $0.id == f.projectID }) { form = nil }
        // 확인 상자는 실행 상태가 바뀔 때마다 다시 만든다. 대상이 사라졌으면 닫는다.
        let nextRemoval = removalTarget.flatMap {
            ManagementPresentation.confirmation(for: $0, registry: registry, activeEnvID: snapshot.active?.envID)
        }
        if nextRemoval == nil { removalTarget = nil }
        if nextRemoval != removal { removal = nextRemoval }
    }
}

/// 상태 분류를 시스템 색으로 바꾼다. 다크·라이트 모드에 맞춰 시스템이 밝기를 조정하는 색만 쓴다.
func toneColor(_ tone: StatusTone) -> Color {
    switch tone {
    case .idle: return Color.secondary
    case .checking, .unavailable: return Color(nsColor: .systemGray)
    case .running: return Color(nsColor: .systemBlue)
    case .passed: return Color(nsColor: .systemGreen)
    case .failed: return Color(nsColor: .systemRed)
    case .attention: return Color(nsColor: .systemOrange)
    }
}

/// 팝오버 전체. 위에서 아래로 경고, 머리(프로젝트·관리 메뉴), 스크롤 영역(환경 목록, 환경 추가, 상세), [종료].
struct PopoverRootView: View {
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 등록하지 않은 Python 환경의 터미널 실행 안내(6단계). 경고가 아니라 안내라 회색으로 보인다.
            if let notice = state.terminalNotice {
                Label(notice, systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.projects.isEmpty {
                emptyProjects(state)
            } else {
                header(state)
                if let confirmation = model.removal, case .project = confirmation.target {
                    RemovalConfirmView(confirmation: confirmation, model: model)
                }
                Divider()
                // 내용이 많아도 팝오버가 화면을 넘지 않게 가운데만 스크롤한다. 머리와 [종료]는 항상 보인다.
                // 상한은 화면 높이에서 정한다(ManagementPresentation.maxScrollHeight).
                // 바깥 .fixedSize 덕분에 내용이 적으면 ScrollView도 내용 높이만큼만 차지한다(아래 frame은 상한일 뿐이다).
                ScrollView {
                    scrollContent(state).padding(.trailing, 4)
                }
                .frame(maxHeight: CGFloat(ManagementPresentation.maxScrollHeight(
                    visibleScreenHeight: NSScreen.main.map { Double($0.visibleFrame.height) })))
            }
            Divider()
            HStack {
                // 7단계 캐릭터 켜고 끄기(사용자 결정 1=A, 기본은 보임). @State를 쓸 수 없어(SwiftUIMacros 없음)
                // 뷰 모델 값을 읽고 쓰는 Binding을 직접 만든다. 값은 AppDelegate가 저장하고 다시 넣어 준다.
                Toggle("캐릭터 보이기", isOn: Binding(get: { model.characterVisible },
                                                    set: { model.onToggleCharacter($0) }))
                    .toggleStyle(.checkbox)
                    .help("화면 구석의 여우 캐릭터를 보이거나 숨깁니다. 캐릭터를 누르면 이 팝오버가 열립니다.")
                Spacer()
                Button("종료") { model.onQuit() }.help("앱을 종료합니다. 실행 중인 pytest는 중지합니다.")
            }
        }
        .padding(12)
        .frame(width: 390, alignment: .leading)
        // 세로는 내용 크기에 맞춘다. 이렇게 해야 안쪽 ScrollView들의 maxHeight가 상한으로 동작하고,
        // 내용이 적을 때 팝오버가 빈 공간을 남기지 않는다.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 프로젝트가 하나도 없을 때: 가운데 큰 "프로젝트 추가" 버튼과 한 줄 안내만.
    @ViewBuilder private func emptyProjects(_ state: PopoverState) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
            Button(action: { model.onAddProject() }) {
                Text("프로젝트 추가").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if let message = state.emptyMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// 머리: 프로젝트 이름(여럿이면 Picker), "+ 프로젝트", 오른쪽 "⋯"(환경 전체 다시 검사, 프로젝트 제거), 아래에 폴더 경로.
    /// "전체 실행"은 9단계 몫이라 두지 않는다.
    @ViewBuilder private func header(_ state: PopoverState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if state.projects.count > 1 {
                    Picker("프로젝트", selection: Binding(get: { state.selectedProjectID },
                                                        set: { model.selectProject($0) })) {
                        ForEach(state.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                } else {
                    Text(state.projects.first?.name ?? "pytest Menu Helper").font(.headline).lineLimit(1)
                }
                Button(action: { model.onAddProject() }) {
                    Label("프로젝트", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("프로젝트 폴더를 추가합니다")
                Spacer()
                if let projectID = state.selectedProjectID {
                    Menu {
                        Button("환경 전체 다시 검사") { model.onRecheckProject(projectID) }
                        Divider()
                        Button("프로젝트 제거...") { model.requestRemoval(.project(projectID)) }
                            .disabled(state.projectRemoveBlockedReason != nil)
                        // 꺼진 이유를 메뉴 안에 바로 보여 준다(4단계 메뉴의 이유 줄과 같다).
                        if let reason = state.projectRemoveBlockedReason { Text(reason) }
                    } label: {
                        Image(systemName: "ellipsis.circle").imageScale(.large)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("프로젝트 관리")
                }
            }
            if let path = state.selectedProjectPath {
                Text(path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path)
            }
        }
    }

    /// 스크롤 영역: 환경 목록(또는 안내), 환경 추가 폼이나 버튼, 선택 환경 상세.
    @ViewBuilder private func scrollContent(_ state: PopoverState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = state.emptyMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                environmentList(state)
            }
            if let form = model.form {
                EnvironmentFormView(form: form, model: model)
            } else {
                Button(action: { model.openAddForm() }) {
                    Label("환경 추가", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            if let detail = state.detail {
                Divider()
                DetailView(detail: detail, model: model)
            }
        }
    }

    /// 환경 목록. 환경이 많으면(5개 이상) 목록만 따로 스크롤해 상세가 아래로 너무 밀리지 않게 한다.
    /// 제거 확인 상자는 그 환경 행 바로 아래에 붙인다(어느 환경을 지우는지 헷갈리지 않게).
    @ViewBuilder private func environmentList(_ state: PopoverState) -> some View {
        let rows = VStack(spacing: 2) {
            ForEach(state.rows) { row in
                EnvRowView(row: row, model: model)
                if let confirmation = model.removal,
                   case .environment(let envID, _) = confirmation.target, envID == row.id {
                    RemovalConfirmView(confirmation: confirmation, model: model)
                }
            }
        }
        if state.rows.count > 4 {
            ScrollView { rows }.frame(maxHeight: 260)
        } else {
            rows
        }
    }
}

/// 환경 한 줄: 상태 점, 이름·Python 버전, 진행 바, 상태 문구, ▶/■ 버튼, "⋯"(다시 검사, 제거).
/// 조치 필요·오류면 아래에 문제 문장과 [명령 복사]가 붙는다. 행을 누르면 선택된다.
struct EnvRowView: View {
    let row: EnvRowModel
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        let color = toneColor(row.tone)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(row.versionText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if let text = row.progressText {
                            Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if row.indeterminate {
                        // 전체 수를 모를 때(수집 대기·수집 전)는 값 없이 움직이는 바.
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    } else if let progress = row.progress {
                        ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small).tint(color)
                    }
                    Text(row.statusText).font(.caption).foregroundStyle(row.tone == .idle ? Color.secondary : color)
                        .lineLimit(1).truncationMode(.tail)
                        .help(row.actionHelp ?? row.statusText) // 긴 이유는 잘리므로 마우스를 올리면 전체를 보여 준다
                }
                actionButton
                moreMenu
            }
            ForEach(row.issues) { line in
                IssueLineView(line: line, copied: model.copiedCommand == line.fixCommand && line.fixCommand != nil) {
                    if let command = line.fixCommand { model.copy(command) }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(row.isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
        // 빈 공간을 눌러도 선택되게 한다. 없으면 글자 위를 눌러야만 선택된다.
        .contentShape(Rectangle())
        .onTapGesture { model.selectEnvironment(row.id) }
    }

    /// ▶ 또는 ■. 버튼 안을 누른 것은 행 선택 제스처보다 버튼이 먼저 받는다.
    @ViewBuilder private var actionButton: some View {
        switch row.action {
        case .run(let enabled):
            Button(action: { model.run(row.id) }) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).disabled(!enabled).help(row.actionHelp ?? "")
        case .stop(let enabled):
            Button(action: { model.onStop() }) { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless).disabled(!enabled).help(row.actionHelp ?? "")
        }
    }

    /// 환경 관리 메뉴. 실행 중인 환경은 "환경 제거"를 끄고 이유를 메뉴 안에 보여 준다.
    private var moreMenu: some View {
        Menu {
            Button("이 환경 다시 검사") { model.onRecheckEnvironment(row.id) }
            Divider()
            Button("환경 제거...") {
                guard let projectID = model.state.selectedProjectID else { return }
                model.requestRemoval(.environment(envID: row.id, projectID: projectID))
            }
            .disabled(row.removeBlockedReason != nil)
            if let reason = row.removeBlockedReason { Text(reason) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("환경 관리")
    }
}

/// 조치 줄 하나: 문제 문장, 설치 명령(고정폭, 한 줄), [명령 복사].
struct IssueLineView: View {
    let line: IssueLine
    /// 방금 이 명령을 복사했는지. 버튼 글자를 "복사됨"으로 바꾼다.
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.text).font(.caption)
                .foregroundStyle(Color(nsColor: line.isError ? .systemRed : .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
            if let command = line.fixCommand {
                HStack(spacing: 6) {
                    // 명령은 길어서 가운데를 줄인다. 전체는 마우스를 올리면 보인다.
                    Text(command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(command)
                    Spacer(minLength: 0)
                    Button(copied ? "복사됨" : "명령 복사", action: onCopy)
                        .controlSize(.small)
                        .help("설치 명령을 클립보드에 복사합니다. 앱은 명령을 실행하지 않습니다.")
                }
            }
        }
    }
}

/// 인라인 제거 확인 상자. 실행 중이면 [제거]를 끄고 이유를 보여 준다.
struct RemovalConfirmView: View {
    let confirmation: RemovalConfirmation
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(confirmation.title).font(.system(size: 12, weight: .semibold))
            Text(confirmation.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            if let reason = confirmation.blockedReason {
                Text(reason).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
            }
            HStack {
                Spacer()
                Button("취소") { model.cancelRemoval() }
                Button("제거") { model.confirmRemoval() }.disabled(!confirmation.canConfirm)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .systemRed).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .systemRed).opacity(0.3)))
    }
}

/// 인라인 "환경 추가" 폼: 후보 Python, "다른 파일 선택...", 이름, [취소][추가].
/// 입력값은 뷰 모델의 form에 있어, 파일 선택 창 때문에 팝오버가 닫혔다 열려도 그대로 남는다.
struct EnvironmentFormView: View {
    let form: EnvironmentFormState
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("환경 추가").font(.system(size: 12, weight: .semibold))
            Text("사용할 Python을 고르세요. 앱은 선택한 Python으로 정보를 읽기만 하고 환경을 바꾸지 않습니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if form.candidates.isEmpty && form.customPath == nil {
                Text("자동으로 찾은 후보가 없습니다(프로젝트 .venv, ~/.venvs). \"다른 파일 선택...\"으로 고르세요.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Python", selection: Binding(get: { form.choice }, set: { model.chooseFormPython($0) })) {
                    ForEach(Array(form.candidates.enumerated()), id: \.offset) { i, candidate in
                        Text("\(candidate.label)  (\(candidate.path))").tag(Optional(PythonChoice.candidate(i)))
                    }
                    if let path = form.customPath {
                        Text("직접 고른 파일  (\(path))").tag(Optional(PythonChoice.custom))
                    }
                }
                .labelsHidden()
            }
            Button("다른 파일 선택...") { model.onChoosePythonFile() }
                .help("Python 실행 파일을 직접 고릅니다(기본 폴더 ~/.venvs). 창이 닫히면 이 폼이 다시 열립니다.")
            TextField("환경 이름", text: Binding(get: { model.form?.name ?? "" }, set: { model.editFormName($0) }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitForm() }
            if let error = form.error {
                Text(error).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { model.cancelForm() }
                Button("추가") { model.submitForm() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// 선택한 환경의 상세: 환경 정보, 제목, 링 3개, 세부 건수, 안내, 실패한 테스트.
struct DetailView: View {
    let detail: EnvDetailModel
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !detail.info.isEmpty {
                // Python 경로와 설치 버전. 경로를 복사할 수 있게 선택 가능으로 둔다.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(detail.info.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(toneColor(detail.tone)).frame(width: 8, height: 8)
                Text(detail.headline).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            HStack(spacing: 0) {
                RingView(ring: detail.progressRing, color: toneColor(.running)).frame(maxWidth: .infinity)
                RingView(ring: detail.passRing, color: toneColor(.passed)).frame(maxWidth: .infinity)
                ElapsedView(text: detail.elapsedText, startedAt: detail.liveStartedAt).frame(maxWidth: .infinity)
            }
            if !detail.counts.isEmpty { CountsView(items: detail.counts) }
            ForEach(Array(detail.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !detail.failures.isEmpty {
                Divider()
                FailureListView(envID: detail.envID, entries: detail.failures, model: model)
            }
        }
    }
}

/// 링 하나. fraction이 nil이면 바탕 링만 그린다(값을 모름).
struct RingView: View {
    let ring: RingModel
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                if let fraction = ring.fraction {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        // 12시 방향에서 시작하게 돌린다. 기본은 3시 방향이다.
                        .rotationEffect(.degrees(-90))
                }
                Text(ring.center).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 6)
            }
            .frame(width: 58, height: 58)
            Text(ring.caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// 오른쪽 칸: 소요 시간. 실행 중이면 0.1초마다 경과 시간을 다시 그린다.
/// TimelineView를 쓰는 이유: 실행 상태 알림은 진행이 바뀔 때만 오므로, 긴 테스트 하나가 도는 동안에는
/// 알림만으로는 시간이 멈춰 보인다.
/// 0.1초 간격인 이유: 10초 미만은 소수 1자리로 보여 주는데, 1초 간격으로 그리면 그리는 시각이 시작 시각과
/// 거의 정수 초만큼 떨어져 있어 소수 자리가 늘 .0으로 멈춰 보였다(사용자 보고, 2026-11-17).
/// 팝오버가 닫혀 있으면 이 뷰도 그려지지 않으므로 0.1초 간격의 비용은 열려 있는 동안에만 든다.
struct ElapsedView: View {
    let text: String
    let startedAt: Date?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                if let start = startedAt {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        label(ResultPresentation.formatElapsed(context.date.timeIntervalSince(start)))
                    }
                } else {
                    label(text)
                }
            }
            .frame(width: 58, height: 58)
            Text("소요 시간").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 6)
    }
}

/// 세부 건수 8개를 4열로 보여 준다. 0인 항목은 흐리게 한다.
struct CountsView: View {
    let items: [CountItem]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: 4),
                  alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    Circle().fill(toneColor(item.tone)).frame(width: 6, height: 6)
                    Text(item.label).lineLimit(1)
                    Text("\(item.value)").fontWeight(.semibold).monospacedDigit()
                }
                .font(.caption)
                .opacity(item.isZero ? 0.4 : 1)
            }
        }
    }
}

/// 실패한 테스트 목록. 목록 전체는 최대 300pt까지만 커지고 넘으면 스크롤한다(팝오버가 화면을 넘지 않게).
struct FailureListView: View {
    let envID: String
    let entries: [FailureEntry]
    /// 펼친 항목은 뷰 모델이 기억한다(@State를 쓸 수 없는 이유는 파일 상단 참고).
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("실패한 테스트 \(entries.count)").font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        let key = envID + "|" + entry.id
                        FailureRowView(entry: entry, isExpanded: model.expandedFailures.contains(key)) {
                            model.toggleFailure(key)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }
}

/// 실패 한 줄. 누르면 펼쳐져 단계별 오류 메시지와 traceback을 보여 준다.
struct FailureRowView: View {
    let entry: FailureEntry
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        // nodeid는 길어서 접힌 상태에서는 가운데를 줄인다(파일명과 테스트 이름이 둘 다 보이게).
                        Text(entry.title).font(.system(size: 11, design: .monospaced))
                            .lineLimit(isExpanded ? nil : 1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(entry.statusLabel).foregroundStyle(toneColor(entry.tone))
                            if let location = entry.locationText {
                                Text(location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        .font(.caption)
                        if !isExpanded, let summary = entry.summary {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(Array(entry.sections.enumerated()), id: \.offset) { _, section in
                    SectionView(section: section)
                }
                .padding(.leading, 16)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// 단계 하나의 실패: 제목, 오류 메시지, traceback(고정폭, 세로 스크롤, 텍스트 선택 가능).
struct SectionView: View {
    let section: FailureSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title).font(.caption).fontWeight(.semibold)
            if let message = section.message {
                Text(message).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let detail = section.detail, !detail.isEmpty {
                // 긴 traceback은 이 상자 안에서만 스크롤한다(최대 220pt). 팝오버 높이를 넘지 않게 하기 위함이다.
                ScrollView {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
            }
        }
    }
}
