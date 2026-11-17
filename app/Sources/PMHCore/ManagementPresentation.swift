// ManagementPresentation.swift
// 팝오버 안의 관리 동작(환경 추가 폼, 제거 확인, 조치 줄, 환경 정보)에 쓰는 순수 코드. AppKit·SwiftUI를 쓰지 않는다.
// 입력: 등록 정보(Registry), 환경 검사 결과(EnvCheck), 지금 실행 중인 환경 id, 폼에 넣은 값.
// 출력: 화면이 그대로 그릴 값(문구, 제거 가능 여부와 이유, 폼 제출 결과).
// 예전에는 이 판단이 AppDelegate의 NSMenu·NSAlert 코드 안에 흩어져 있었다. 팝오버로 옮기면서 한곳에 모아
// 단위 테스트로 고정한다(ManagementTests). 화면(PopoverView)과 앱 동작(AppDelegate)이 같은 함수를 쓰므로
// "화면에서는 꺼져 있는데 동작은 통과" 같은 어긋남이 생기지 않는다.

import Foundation

// MARK: 제거

/// 제거할 대상. 환경은 어느 프로젝트에 속하는지도 함께 들고 다닌다(같은 환경 id를 프로젝트 안에서 찾기 위함).
public enum RemovalTarget: Equatable {
    case project(UUID)
    case environment(envID: String, projectID: UUID)
}

/// 팝오버 안 인라인 제거 확인 상자의 내용.
public struct RemovalConfirmation: Equatable {
    public var target: RemovalTarget
    /// 예: "프로젝트 \"demo\" 제거".
    public var title: String
    /// 확인 문장. 등록 정보만 지운다는 사실을 꼭 알린다(폴더를 지우는 것으로 오해하지 않게).
    public var message: String
    /// 지금 제거할 수 없는 이유(실행 중). nil이면 제거할 수 있다.
    public var blockedReason: String?
    /// [제거] 버튼을 켤지.
    public var canConfirm: Bool { blockedReason == nil }
}

/// 환경 행 아래에 보여 줄 조치 줄 하나(문제 문장과 복사할 설치 명령).
public struct IssueLine: Equatable, Identifiable {
    /// 같은 환경 안에서 유일한 값. 문제 코드는 환경 안에서 겹치지 않는다(Interpreter가 코드당 1건만 만든다).
    public var id: String
    /// 예: "조치 필요: pytest-menu-helper 플러그인이 설치되어 있지 않습니다."
    public var text: String
    /// 오류면 true(빨강), 조치 필요면 false(주황).
    public var isError: Bool
    /// [명령 복사]로 클립보드에 넣을 명령. 없으면 버튼을 숨긴다. 앱은 이 명령을 실행하지 않는다.
    public var fixCommand: String?
}

/// 관리 화면 값을 만드는 함수 모음. 모두 입력만 보고 결과를 돌려주는 순수 함수다.
public enum ManagementPresentation {
    /// 실행 중이라 제거를 막을 때의 이유 문장. 4단계 메뉴와 같은 문장을 그대로 쓴다.
    public static let removeBlockedReason = "실행 중에는 제거할 수 없습니다. 먼저 중지하세요."
    /// 제거 확인 문장.
    public static let removeConfirmMessage = "정말 제거할까요? 등록 정보만 지우고 폴더·환경은 그대로 둡니다."

    /// 프로젝트를 지금 제거할 수 없는 이유.
    /// - Parameters:
    ///   - project: 대상 프로젝트.
    ///   - activeEnvID: 지금 실행 중인 환경 id(없으면 nil).
    /// - Returns: 그 프로젝트의 환경이 실행 중이면 이유 문장, 아니면 nil.
    /// 막는 이유: 실행 중인 환경을 등록에서 지우면 팝오버에서 그 행(■ 중지 버튼)이 사라져, 그 실행이 끝날 때까지
    /// 멈출 방법이 없고 다른 환경의 ▶도 꺼진 채 남는다.
    public static func projectRemovalBlockedReason(_ project: Project, activeEnvID: String?) -> String? {
        guard let active = activeEnvID, project.environments.contains(where: { $0.id == active }) else { return nil }
        return removeBlockedReason
    }

    /// 환경을 지금 제거할 수 없는 이유. 실행 중인 환경 자신이면 이유 문장, 아니면 nil(이유는 위 함수와 같다).
    public static func environmentRemovalBlockedReason(envID: String, activeEnvID: String?) -> String? {
        activeEnvID == envID ? removeBlockedReason : nil
    }

    /// 제거 확인 상자 내용을 만든다.
    /// - Parameters:
    ///   - target: 사용자가 제거를 누른 대상.
    ///   - registry: 지금 등록 정보.
    ///   - activeEnvID: 지금 실행 중인 환경 id.
    /// - Returns: 대상이 등록에서 이미 사라졌으면 nil(화면은 확인 상자를 닫는다). 있으면 확인 내용.
    /// 확인 상자가 떠 있는 동안 실행이 시작되면 blockedReason이 채워져 [제거]가 꺼진다(뷰 모델이 상태가 바뀔 때마다 다시 부른다).
    public static func confirmation(for target: RemovalTarget, registry: Registry,
                                    activeEnvID: String?) -> RemovalConfirmation? {
        switch target {
        case .project(let id):
            guard let project = registry.projects.first(where: { $0.id == id }) else { return nil }
            return RemovalConfirmation(target: target, title: "프로젝트 \"\(project.name)\" 제거",
                                       message: removeConfirmMessage,
                                       blockedReason: projectRemovalBlockedReason(project, activeEnvID: activeEnvID))
        case .environment(let envID, let projectID):
            guard let project = registry.projects.first(where: { $0.id == projectID }),
                  let env = project.environments.first(where: { $0.id == envID }) else { return nil }
            return RemovalConfirmation(target: target, title: "환경 \"\(env.name)\" 제거",
                                       message: removeConfirmMessage,
                                       blockedReason: environmentRemovalBlockedReason(envID: envID, activeEnvID: activeEnvID))
        }
    }

    // MARK: 조치 줄과 환경 정보

    /// 환경 행 아래에 보여 줄 조치 줄.
    /// - Parameter check: 검사 결과. nil(검사 중)이거나 준비됨이면 빈 목록.
    /// - Returns: 검사기가 만든 문제를 순서 그대로. 준비됨이 아니면 모든 문제를 보여 준다
    ///   (Interpreter가 만드는 문제는 모두 조치 필요나 오류 등급이라, 준비됨 상태에는 문제가 없다).
    public static func issueLines(_ check: EnvCheck?) -> [IssueLine] {
        guard let check = check, check.status != .ready else { return [] }
        return check.issues.map {
            IssueLine(id: $0.code.rawValue, text: "\($0.severity.label): \($0.message)",
                      isError: $0.severity == .error, fixCommand: $0.fixCommand)
        }
    }

    /// 상세 쪽에 보여 줄 환경 정보 줄(Python 경로, 설치된 버전).
    /// - Parameters:
    ///   - env: 환경 등록 정보.
    ///   - check: 검사 결과. 검사 중이면 nil, 검사기가 정보를 읽지 못했으면 report가 nil.
    /// - Returns: 경로 줄은 항상, 버전 줄은 검사 결과에 정보가 있을 때만.
    public static func environmentInfo(env: PMHEnvironment, check: EnvCheck?) -> [String] {
        var lines = ["Python 경로: \(env.pythonPath)"]
        guard let check = check else {
            lines.append("환경 정보는 검사가 끝나면 보입니다.")
            return lines
        }
        guard let report = check.report else { return lines }
        let plugin = report.pluginInstalled ? "설치됨 \(report.pluginVersion ?? "(버전 불명)")" : "없음"
        lines.append("Python \(report.pythonVersionText) · pytest \(report.pytestVersion ?? "없음") · "
                     + "FastAPI \(report.fastapiVersion ?? "없음") · 플러그인 \(plugin)")
        return lines
    }

    /// 상세 맨 끝에 붙일 "다른 터미널 실행 감지" 조건 안내(6단계).
    /// - Parameter check: 환경 검사 결과. 검사 중이거나 Python 자체를 쓸 수 없으면 nil을 돌려준다(먼저 고칠 문제가 있다).
    /// - Returns: 플러그인이 없으면 감지할 수 없다는 문장, 0.2.x면 끝 확인 불가 문장, 그 밖에는 감지 조건과 끄는 조건.
    /// 끄는 조건을 꼭 적는 이유: 자동 로드를 끈 실행은 기록 자체가 없어 앱이 "감지 안 됨"을 알려 줄 방법이 없다.
    public static func terminalDetectionNote(_ check: EnvCheck?) -> String? {
        guard let check = check, let report = check.report, report.pytestVersion != nil else { return nil }
        if !report.pluginInstalled {
            return "터미널 감지 불가: 플러그인이 없어 이 환경의 pytest 실행이 기록되지 않습니다."
        }
        if !Interpreter.pluginSupportsRunID(report.pluginVersion) { return nil } // 구버전 안내(조치 줄)가 먼저다
        let off = "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1(이때는 -p pytest_menu_helper.plugin으로 켬), "
            + "-p no:pytest_menu_helper.plugin, PYTEST_MENU_DISABLE=1로 실행하면 기록되지 않습니다."
        if check.issues.contains(where: { $0.code == .pluginNoTerminalSupport }) {
            return "터미널 감지: 실행은 보이지만 끝났는지 확인할 수 없습니다(플러그인 0.3.0 이상 필요). " + off
        }
        return "터미널 감지: 다른 터미널에서 이 프로젝트 폴더(또는 하위 폴더)로 이동해 이 환경의 python -m pytest를 실행해도 여기에 보입니다. " + off
    }

    // MARK: 레이아웃

    /// 팝오버의 스크롤 영역 최대 높이.
    /// - Parameter visibleScreenHeight: 화면에서 메뉴 막대·Dock을 뺀 높이(NSScreen.visibleFrame.height). 모르면 nil.
    /// - Returns: 머리·바닥 줄과 팝오버 화살표 몫(160pt)을 뺀 값. 너무 작은 화면에서도 240pt는 남긴다.
    /// 상한을 두지 않으면 실패 목록을 여럿 펼쳤을 때 팝오버가 화면 아래로 넘어가 [종료] 버튼에 닿을 수 없다.
    public static func maxScrollHeight(visibleScreenHeight: Double?) -> Double {
        guard let h = visibleScreenHeight, h > 0 else { return 600 }
        return max(h - 160, 240)
    }
}

// MARK: 환경 추가 폼

/// 폼에서 고른 Python. 후보 목록의 순번이거나, 파일 선택 창으로 직접 고른 파일이다.
public enum PythonChoice: Hashable {
    case candidate(Int)
    case custom
}

/// 폼 제출 결과.
public enum FormSubmission: Equatable {
    /// 등록할 수 있다. name은 앞뒤 공백을 지운 값이며, 비어 있었으면 자동 이름으로 채운다.
    case ready(pythonPath: String, name: String)
    /// 등록할 수 없다. 문장을 폼 아래에 보여 준다.
    case invalid(String)
}

/// 팝오버 안 "환경 추가" 인라인 폼의 상태. 화면은 이 값을 그리고, 사용자 입력은 mutating 함수로만 바꾼다.
/// 자동 이름 규칙(예전 EnvironmentForm과 같음): Python을 바꿀 때, 이름이 비었거나 직전 자동 이름 그대로면
/// 새 자동 이름으로 갈아 끼우고, 사용자가 고친 이름이면 그대로 둔다.
public struct EnvironmentFormState: Equatable {
    /// 폼이 속한 프로젝트. 다른 프로젝트로 바꾸면 뷰 모델이 폼을 닫는다.
    public let projectID: UUID
    /// 후보 Python(이미 등록한 경로는 만들 때 빼 둔다).
    public let candidates: [PythonCandidate]
    /// 지금 고른 Python. 후보도 직접 고른 파일도 없으면 nil.
    public private(set) var choice: PythonChoice?
    /// 파일 선택 창으로 고른 경로. 고른 적이 없으면 nil.
    public private(set) var customPath: String?
    /// 이름 칸의 값.
    public private(set) var name: String
    /// 마지막으로 자동으로 넣은 이름. 이름 칸이 이 값과 같으면 "사용자가 고치지 않았다"로 본다.
    private var autoName: String
    /// 제출에 실패한 이유. 사용자가 무엇이든 다시 고르거나 고치면 지운다.
    public var error: String?

    /// - Parameters:
    ///   - projectID: 폼이 속한 프로젝트 id.
    ///   - candidates: 보여 줄 후보. 첫 후보를 기본으로 고른다(예전 팝업 메뉴의 기본 선택과 같다).
    public init(projectID: UUID, candidates: [PythonCandidate]) {
        self.projectID = projectID
        self.candidates = candidates
        self.choice = nil
        self.customPath = nil
        self.name = ""
        self.autoName = ""
        self.error = nil
        choose(candidates.isEmpty ? nil : .candidate(0))
    }

    /// 지금 고른 Python 경로. 고른 것이 없거나 순번이 범위를 벗어나면 nil.
    public var selectedPythonPath: String? {
        switch choice {
        case .candidate(let i): return candidates.indices.contains(i) ? candidates[i].path : nil
        case .custom: return customPath
        case nil: return nil
        }
    }

    /// Python을 고른다.
    /// - Parameter newChoice: 후보 순번 또는 .custom. 범위 밖 순번이나 직접 고른 파일이 없는 .custom은 무시한다
    ///   (화면이 갱신되기 전 낡은 선택이 들어와도 상태를 깨지 않기 위함).
    public mutating func choose(_ newChoice: PythonChoice?) {
        switch newChoice {
        case .candidate(let i) where !candidates.indices.contains(i): return
        case .custom where customPath == nil: return
        default: break
        }
        choice = newChoice
        error = nil
        refreshAutoName()
    }

    /// 파일 선택 창에서 고른 경로를 넣고 그 파일을 고른 상태로 만든다.
    /// 심볼릭 링크를 풀지 않는다. 가상환경은 bin/python 경로 자체가 환경을 가리키기 때문이다.
    public mutating func setCustomPath(_ path: String) {
        customPath = path
        choose(.custom)
    }

    /// 사용자가 이름 칸을 고쳤다. 고친 이름은 이후 Python을 바꿔도 유지된다(autoName과 달라지므로).
    public mutating func editName(_ text: String) {
        name = text
        error = nil
    }

    /// 고른 Python에 맞춰 자동 이름을 다시 정한다. 이름을 사용자가 고쳤으면 칸은 건드리지 않는다.
    private mutating func refreshAutoName() {
        let next = selectedPythonPath.map { defaultEnvironmentName(forPython: $0) } ?? ""
        if name.isEmpty || name == autoName { name = next }
        autoName = next
    }

    /// 제출할 수 있는지 판정한다.
    /// - Parameter registeredPaths: 이 프로젝트에 이미 등록한 Python 경로들(폼을 연 뒤 바뀌었을 수 있어 제출 때 다시 받는다).
    /// - Returns: 등록할 값, 또는 막힌 이유. 이름이 공백뿐이면 자동 이름을 쓴다.
    public func submission(registeredPaths: Set<String>) -> FormSubmission {
        guard let path = selectedPythonPath, !path.isEmpty else {
            return .invalid("Python을 고르세요. 후보가 없으면 \"다른 파일 선택...\"으로 고를 수 있습니다.")
        }
        if registeredPaths.contains(path) {
            return .invalid("이 프로젝트에 이미 등록한 Python입니다.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .ready(pythonPath: path, name: trimmed.isEmpty ? defaultEnvironmentName(forPython: path) : trimmed)
    }
}

// MARK: 프로젝트 폴더 (8단계)

/// [폴더 다시 지정]의 결과.
public enum ProjectRelocation: Equatable {
    /// 경로만 바꾼 새 등록 정보. 프로젝트 id와 환경 목록(id·이름·Python 경로)은 그대로다.
    case relocated(Registry)
    /// 바꾸지 않았다. 매개변수는 팝오버 위에 보일 이유 문장.
    case rejected(String)
}

/// 프로젝트 폴더가 사라졌을 때의 판단. 모두 순수 함수이고 파일 시스템 확인은 호출하는 쪽이 넘긴다.
public enum ProjectFolderCheck {
    /// 프로젝트 줄에 보일 오류 문장. 실행 때 RunController가 내는 오류("프로젝트 폴더가 없습니다: <경로>")와 앞부분을 맞춘다.
    public static let missingMessage = "프로젝트 폴더가 없습니다"
    /// 다시 지정하려는 폴더가 이미 다른 프로젝트로 등록돼 있을 때.
    public static let duplicateMessage = "이미 다른 프로젝트로 등록한 폴더입니다. 그 프로젝트를 쓰거나 먼저 제거하세요."

    /// 폴더가 없는 프로젝트 id 모음.
    /// - Parameters:
    ///   - registry: 등록 정보.
    ///   - isDirectory: 경로가 지금 폴더로 있는지 알려 주는 함수. 앱은 FileManager로, 테스트는 가짜로 넘긴다.
    /// - Returns: isDirectory가 false인 프로젝트의 id. 파일로 바뀐 경로도 폴더가 아니므로 없는 것으로 본다
    ///   (pytest를 그 경로에서 실행할 수 없다).
    public static func missing(_ registry: Registry, isDirectory: (String) -> Bool) -> Set<UUID> {
        Set(registry.projects.filter { !isDirectory($0.path) }.map(\.id))
    }

    /// 프로젝트 경로만 새 폴더로 바꾼다(사용자 결정 4, 2026-11-17: 환경 등록은 유지).
    /// - Parameters:
    ///   - registry: 지금 등록 정보.
    ///   - projectID: 바꿀 프로젝트. 등록에 없으면 rejected.
    ///   - path: 새 폴더 경로.
    /// - Returns: 바뀐 등록 정보, 또는 막은 이유.
    /// 같은 폴더가 다른 프로젝트로 이미 등록돼 있으면 막는다. 허용하면 같은 폴더가 프로젝트 둘로 보여
    /// 터미널 실행 연결(ExternalMatching)이 어느 쪽에 붙을지 정할 수 없다.
    /// 자기 자신과 같은 경로(폴더를 원래 이름으로 되돌린 뒤 다시 고름)는 바꾸지 않고 그대로 돌려준다.
    public static func relocate(_ registry: Registry, projectID: UUID, to path: String) -> ProjectRelocation {
        guard let index = registry.projects.firstIndex(where: { $0.id == projectID }) else {
            return .rejected("프로젝트를 찾지 못했습니다. 이미 제거됐을 수 있습니다.")
        }
        if registry.projects.contains(where: { $0.id != projectID && $0.path == path }) {
            return .rejected(duplicateMessage)
        }
        var next = registry
        next.projects[index].path = path
        return .relocated(next)
    }
}
