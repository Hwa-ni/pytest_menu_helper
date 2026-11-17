// ManagementTests.swift
// 팝오버로 옮긴 관리 동작의 순수 로직(ManagementPresentation, EnvironmentFormState)과
// PopoverState에 새로 붙은 값(조치 줄, 제거 막기 이유, 환경 정보, 프로젝트 경로)을 검사한다.
// 화면(SwiftUI)과 선택 창은 자동으로 확인하지 못하므로, 화면이 그대로 쓰는 판단을 여기서 고정한다.

import Foundation
import Testing
@testable import PMHCore

private let e1 = PMHEnvironment(id: "e1", name: "pmh-3.12", pythonPath: "/h/.venvs/pmh-3.12/bin/python")
private let e2 = PMHEnvironment(id: "e2", name: "pmh-3.13", pythonPath: "/h/.venvs/pmh-3.13/bin/python")

/// 실행 중 상태. envID 환경이 실행 중인 스냅숏을 만든다.
private func running(_ envID: String) -> RunSnapshot {
    RunSnapshot(active: ActiveRun(runID: "r", envID: envID, projectPath: "/w/a",
                                  phase: .waitingForEvents, stopping: false))
}

private func candidates() -> [PythonCandidate] {
    [PythonCandidate(path: "/w/a/.venv/bin/python", label: "프로젝트 .venv"),
     PythonCandidate(path: "/h/.venvs/pmh-3.13/bin/python", label: "~/.venvs/pmh-3.13")]
}

// MARK: 제거 가능 여부

@Suite struct RemovalPolicyTests {
    let project = Project(path: "/w/demo", environments: [e1, e2])

    @Test func projectBlockedOnlyWhileItsEnvironmentRuns() {
        #expect(ManagementPresentation.projectRemovalBlockedReason(project, activeEnvID: nil) == nil)
        #expect(ManagementPresentation.projectRemovalBlockedReason(project, activeEnvID: "other") == nil)
        #expect(ManagementPresentation.projectRemovalBlockedReason(project, activeEnvID: "e2")
                == ManagementPresentation.removeBlockedReason)
    }

    @Test func environmentBlockedOnlyWhenItselfRuns() {
        #expect(ManagementPresentation.environmentRemovalBlockedReason(envID: "e1", activeEnvID: "e1") != nil)
        // 같은 프로젝트의 다른 환경이 실행 중이어도 이 환경은 지울 수 있다(■ 중지 버튼이 남기 때문이다).
        #expect(ManagementPresentation.environmentRemovalBlockedReason(envID: "e1", activeEnvID: "e2") == nil)
        #expect(ManagementPresentation.environmentRemovalBlockedReason(envID: "e1", activeEnvID: nil) == nil)
    }

    @Test func confirmationTextAndBlockedState() throws {
        let reg = Registry(projects: [project])
        let p = try #require(ManagementPresentation.confirmation(for: .project(project.id), registry: reg, activeEnvID: nil))
        #expect(p.title == "프로젝트 \"demo\" 제거")
        #expect(p.message == "정말 제거할까요? 등록 정보만 지우고 폴더·환경은 그대로 둡니다.")
        #expect(p.canConfirm)
        let env = try #require(ManagementPresentation.confirmation(
            for: .environment(envID: "e1", projectID: project.id), registry: reg, activeEnvID: "e1"))
        #expect(env.title == "환경 \"pmh-3.12\" 제거")
        #expect(!env.canConfirm && env.blockedReason == ManagementPresentation.removeBlockedReason)
    }

    /// 확인 상자가 떠 있는 동안 대상이 사라지면 nil이라 화면이 상자를 닫는다.
    @Test func confirmationForMissingTargetIsNil() {
        let reg = Registry(projects: [project])
        #expect(ManagementPresentation.confirmation(for: .project(UUID()), registry: reg, activeEnvID: nil) == nil)
        #expect(ManagementPresentation.confirmation(for: .environment(envID: "gone", projectID: project.id),
                                                    registry: reg, activeEnvID: nil) == nil)
        #expect(ManagementPresentation.confirmation(for: .environment(envID: "e1", projectID: UUID()),
                                                    registry: reg, activeEnvID: nil) == nil)
    }
}

// MARK: 조치 줄과 환경 정보

@Suite struct IssueAndInfoTests {
    @Test func issueLinesOnlyWhenNotReady() {
        #expect(ManagementPresentation.issueLines(nil).isEmpty)
        #expect(ManagementPresentation.issueLines(EnvCheck(status: .ready, report: nil, issues: [])).isEmpty)
        let check = EnvCheck(status: .error, report: nil, issues: [
            PMHCore.Issue(code: .pytestMissing, severity: .error, message: "pytest가 없습니다.", fixCommand: "uv pip install pytest"),
            PMHCore.Issue(code: .fastapiMissing, severity: .actionNeeded, message: "FastAPI가 없습니다.", fixCommand: nil),
        ])
        let lines = ManagementPresentation.issueLines(check)
        #expect(lines.map(\.text) == ["오류: pytest가 없습니다.", "조치 필요: FastAPI가 없습니다."])
        #expect(lines.map(\.isError) == [true, false])
        #expect(lines.map(\.fixCommand) == ["uv pip install pytest", nil])
        #expect(Set(lines.map(\.id)).count == 2) // 화면 반복 식별자가 겹치지 않는다
    }

    @Test func environmentInfoLines() {
        #expect(ManagementPresentation.environmentInfo(env: e1, check: nil)
                == ["Python 경로: \(e1.pythonPath)", "환경 정보는 검사가 끝나면 보입니다."])
        // 실행할 수 없는 Python처럼 검사 정보가 없으면 경로만.
        #expect(ManagementPresentation.environmentInfo(env: e1, check: EnvCheck(status: .error, report: nil, issues: []))
                == ["Python 경로: \(e1.pythonPath)"])
        let report = CheckReport(pythonVersion: [3, 12, 4], pytestVersion: "8.4.0", fastapiVersion: nil,
                                 pluginInstalled: true, pluginVersion: nil)
        let lines = ManagementPresentation.environmentInfo(env: e1, check: EnvCheck(status: .ready, report: report, issues: []))
        #expect(lines.last == "Python 3.12.4 · pytest 8.4.0 · FastAPI 없음 · 플러그인 설치됨 (버전 불명)")
    }

    @Test func maxScrollHeightLeavesRoomAndHasFloor() {
        #expect(ManagementPresentation.maxScrollHeight(visibleScreenHeight: 900) == 740)
        #expect(ManagementPresentation.maxScrollHeight(visibleScreenHeight: 300) == 240)
        #expect(ManagementPresentation.maxScrollHeight(visibleScreenHeight: nil) == 600)
    }
}

// MARK: 환경 추가 폼

@Suite struct EnvironmentFormTests {
    let projectID = UUID()

    @Test func firstCandidateSelectedWithAutoName() {
        let form = EnvironmentFormState(projectID: projectID, candidates: candidates())
        #expect(form.choice == .candidate(0))
        #expect(form.selectedPythonPath == "/w/a/.venv/bin/python")
        #expect(form.name == ".venv")
    }

    @Test func autoNameFollowsSelectionUntilUserEdits() {
        var form = EnvironmentFormState(projectID: projectID, candidates: candidates())
        form.choose(.candidate(1))
        #expect(form.name == "pmh-3.13")
        form.editName("내 환경")
        form.choose(.candidate(0))
        #expect(form.name == "내 환경") // 사용자가 고친 이름은 유지
        // 이름을 지우면 다시 자동 이름을 받는다.
        form.editName("")
        form.choose(.candidate(1))
        #expect(form.name == "pmh-3.13")
        // 직접 자동 이름과 같게 고친 경우도 자동 이름으로 본다(예전 EnvironmentForm과 같은 규칙).
        form.editName("pmh-3.13")
        form.setCustomPath("/opt/py/venv-x/bin/python")
        #expect(form.name == "venv-x" && form.choice == .custom)
    }

    @Test func invalidChoicesAreIgnored() {
        var form = EnvironmentFormState(projectID: projectID, candidates: candidates())
        form.choose(.candidate(5))
        #expect(form.choice == .candidate(0))
        form.choose(.custom) // 직접 고른 파일이 아직 없다
        #expect(form.choice == .candidate(0))
    }

    @Test func noCandidatesStartsEmpty() {
        let form = EnvironmentFormState(projectID: projectID, candidates: [])
        #expect(form.choice == nil && form.selectedPythonPath == nil && form.name.isEmpty)
        if case .invalid = form.submission(registeredPaths: []) {} else { Testing.Issue.record("Python 없이 제출되면 안 된다") }
    }

    @Test func submissionTrimsNameAndRejectsDuplicates() {
        var form = EnvironmentFormState(projectID: projectID, candidates: candidates())
        form.editName("  dev  ")
        #expect(form.submission(registeredPaths: []) == .ready(pythonPath: "/w/a/.venv/bin/python", name: "dev"))
        form.editName("   ")
        #expect(form.submission(registeredPaths: []) == .ready(pythonPath: "/w/a/.venv/bin/python", name: ".venv"))
        #expect(form.submission(registeredPaths: ["/w/a/.venv/bin/python"])
                == .invalid("이 프로젝트에 이미 등록한 Python입니다."))
    }

    @Test func errorClearsWhenUserChangesInput() {
        var form = EnvironmentFormState(projectID: projectID, candidates: candidates())
        form.error = "x"
        form.editName("a")
        #expect(form.error == nil)
        form.error = "x"
        form.choose(.candidate(1))
        #expect(form.error == nil)
    }
}

// MARK: PopoverState에 붙은 관리 값

@Suite struct PopoverManagementStateTests {
    @Test func rowsCarryIssuesAndRemoveBlock() {
        let a = Project(path: "/w/a", environments: [e1, e2])
        let checks = ["e1": EnvCheck(status: .ready, report: nil, issues: []),
                      "e2": EnvCheck(status: .ready, report: nil, issues: [])]
        let state = ResultPresentation.build(registry: Registry(projects: [a]), checks: checks, snapshot: running("e1"),
                                             preferredProjectID: nil, preferredEnvID: nil)
        #expect(state.selectedProjectPath == "/w/a")
        #expect(state.projectRemoveBlockedReason == ManagementPresentation.removeBlockedReason)
        #expect(state.rows.map(\.removeBlockedReason) == [ManagementPresentation.removeBlockedReason, nil])
        #expect(state.detail?.info.first == "Python 경로: \(e1.pythonPath)")
        let idle = ResultPresentation.build(registry: Registry(projects: [a]), checks: checks, snapshot: RunSnapshot(),
                                            preferredProjectID: nil, preferredEnvID: nil)
        #expect(idle.projectRemoveBlockedReason == nil && idle.rows.allSatisfy { $0.removeBlockedReason == nil })
    }

    /// 조치 줄에 없는 이유(검사기가 만든 문제가 아닌 경우)는 행 문구에 그대로 적는다.
    @Test func reasonNotListedBelowIsShownInFull() {
        let check = EnvCheck(status: .error, report: nil, issues: [])
        let row = ResultPresentation.row(env: e1, check: check, snapshot: RunSnapshot(), selected: false)
        #expect(row.issues.isEmpty)
        #expect(row.statusText == "실행 전") // 문제 없이 오류인 결과는 실행 불가 이유도 없다(RunEligibility 기준)
        let errorCheck = EnvCheck(status: .error, report: nil,
                                  issues: [PMHCore.Issue(code: .pathMissing, severity: .error, message: "경로가 없습니다.", fixCommand: nil)])
        let blocked = ResultPresentation.row(env: e1, check: errorCheck, snapshot: RunSnapshot(), selected: false)
        #expect(blocked.statusText == "실행 불가: 아래 문제를 먼저 해결하세요.")
        #expect(blocked.issues.map(\.text) == ["오류: 경로가 없습니다."])
    }

    @Test func emptyMessagesPointToPopoverButtons() {
        let none = ResultPresentation.build(registry: Registry(), checks: [:], snapshot: RunSnapshot(),
                                            preferredProjectID: nil, preferredEnvID: nil)
        #expect(none.emptyMessage?.contains("⚙") == false && none.selectedProjectPath == nil)
        let b = Project(path: "/w/b")
        let noEnv = ResultPresentation.build(registry: Registry(projects: [b]), checks: [:], snapshot: RunSnapshot(),
                                             preferredProjectID: nil, preferredEnvID: nil)
        #expect(noEnv.emptyMessage?.contains("+ 환경 추가") == true && noEnv.selectedProjectPath == "/w/b")
    }
}
