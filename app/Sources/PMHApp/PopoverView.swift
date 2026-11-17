// PopoverView.swift
// 메뉴 막대 아이콘을 왼쪽 클릭하면 열리는 팝오버의 SwiftUI 화면(5단계 결과 목록과 실패 상세).
// 입력: PopoverViewModel이 들고 있는 PopoverState(PMHCore의 ResultPresentation이 만든 값).
// 출력: 화면과 사용자 동작(프로젝트·환경 선택, 실행, 중지, 설정 메뉴 열기)을 뷰 모델의 콜백으로 넘긴다.
// 이 파일은 그리기만 한다. 문구·건수·링 값·실패 목록·기본 선택은 모두 PMHCore에서 정하고 단위 테스트로 고정했다.
// 색은 시스템 색(NSColor.system*)과 .secondary만 써서 다크·라이트 모드 모두 시스템이 대비를 맞추게 한다.
// 주의: SwiftUI의 @State는 이 SDK에서 매크로로 구현되어 있고, Command Line Tools에는 그 매크로 플러그인
// (SwiftUIMacros)이 없어 컴파일되지 않는다. 그래서 화면 안의 상태(펼친 실패 항목)도 뷰 모델의 @Published에 둔다.
// @Published·@ObservedObject는 매크로가 아니라 속성 래퍼라 문제없다.

import AppKit
import PMHCore
import SwiftUI

/// 팝오버 화면의 상태와 동작을 잇는 뷰 모델. 메인 스레드에서만 쓴다.
/// AppDelegate가 등록 정보·검사 결과·실행 상태가 바뀔 때마다 update를 부르고,
/// 화면은 @Published state가 바뀌면 다시 그린다. 그래서 팝오버가 열린 채로도 실행 상태가 실시간으로 보인다.
final class PopoverViewModel: ObservableObject {
    /// 화면이 그릴 값. 같은 값이면 다시 넣지 않아 불필요한 다시 그리기를 막는다.
    @Published private(set) var state = PopoverState.empty
    /// 펼친 실패 항목. "환경 id|항목 id"로 기억해, 환경을 바꿨을 때 다른 환경의 같은 id 항목이 펼쳐지지 않게 한다.
    /// 실행이 다시 끝나도 같은 테스트가 또 실패하면 펼친 채로 남는다(같은 id).
    @Published private(set) var expandedFailures: Set<String> = []

    /// 실행(▶) 요청. 매개변수는 환경 id.
    var onRun: (String) -> Void = { _ in }
    /// 중지(■) 요청. 동시에 1건만 실행되므로 대상 환경을 따로 넘기지 않는다.
    var onStop: () -> Void = {}
    /// ⚙ 버튼. 기존 NSMenu를 연다.
    var onSettings: () -> Void = {}

    private var registry = Registry()
    private var checks: [String: EnvCheck] = [:]
    private var snapshot = RunSnapshot()
    /// 사용자가 고른 프로젝트·환경. nil이면 기본 선택(실행 중인 환경, 없으면 첫 환경)을 쓴다.
    private var preferredProjectID: UUID?
    private var preferredEnvID: String?

    /// 입력을 바꾸고 화면 값을 다시 만든다.
    func update(registry: Registry, checks: [String: EnvCheck], snapshot: RunSnapshot) {
        self.registry = registry; self.checks = checks; self.snapshot = snapshot
        recompute()
    }

    /// 팝오버를 열 때 부른다. 지난번에 고른 환경 대신 기본 선택(지금 실행 중인 환경)부터 보여 주기 위함이다.
    func resetSelection() {
        preferredProjectID = nil; preferredEnvID = nil
        recompute()
    }

    /// 프로젝트를 바꾸면 환경 선택은 새 프로젝트의 기본값으로 돌린다(다른 프로젝트의 환경 id가 남지 않게).
    func selectProject(_ id: UUID?) {
        preferredProjectID = id; preferredEnvID = nil
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

    private func recompute() {
        let next = ResultPresentation.build(registry: registry, checks: checks, snapshot: snapshot,
                                            preferredProjectID: preferredProjectID, preferredEnvID: preferredEnvID)
        if next != state { state = next }
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

/// 팝오버 전체. 위에서 아래로 머리, 환경 목록, 선택 환경 상세, 실패한 테스트 순서다.
struct PopoverRootView: View {
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 10) {
            header(state)
            Divider()
            if let message = state.emptyMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                environmentList(state)
                if let detail = state.detail {
                    Divider()
                    DetailView(detail: detail, model: model)
                }
            }
        }
        .padding(12)
        .frame(width: 390, alignment: .leading)
        // 세로는 내용 크기에 맞춘다. 이렇게 해야 아래 ScrollView들의 maxHeight가 상한으로 동작하고,
        // 내용이 적을 때 팝오버가 빈 공간을 남기지 않는다.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 머리: 프로젝트 이름(여럿이면 Picker), ⚙ 버튼. "전체 실행"은 9단계 몫이라 두지 않는다.
    @ViewBuilder private func header(_ state: PopoverState) -> some View {
        HStack(spacing: 8) {
            if state.projects.count > 1 {
                Picker("프로젝트", selection: Binding(get: { state.selectedProjectID },
                                                    set: { model.selectProject($0) })) {
                    ForEach(state.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            } else {
                Text(state.projects.first?.name ?? "pytest Menu Helper").font(.headline).lineLimit(1)
            }
            Spacer()
            Button(action: { model.onSettings() }) {
                Image(systemName: "gearshape").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help("프로젝트·환경 관리와 종료 메뉴")
        }
    }

    /// 환경 목록. 환경이 많으면(5개 이상) 목록만 따로 스크롤해 상세가 화면 밖으로 밀리지 않게 한다.
    @ViewBuilder private func environmentList(_ state: PopoverState) -> some View {
        let rows = VStack(spacing: 2) {
            ForEach(state.rows) { row in
                EnvRowView(row: row, onSelect: { model.selectEnvironment(row.id) },
                           onRun: { model.run(row.id) }, onStop: { model.onStop() })
            }
        }
        if state.rows.count > 4 {
            ScrollView { rows }.frame(maxHeight: 200)
        } else {
            rows
        }
    }
}

/// 환경 한 줄: 상태 점, 이름·Python 버전, 진행 바, 상태 문구, ▶/■ 버튼. 행을 누르면 선택된다.
struct EnvRowView: View {
    let row: EnvRowModel
    let onSelect: () -> Void
    let onRun: () -> Void
    let onStop: () -> Void

    var body: some View {
        let color = toneColor(row.tone)
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
                    .help(row.statusText) // 긴 실행 불가 이유는 잘리므로 마우스를 올리면 전체를 보여 준다
            }
            actionButton
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(row.isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
        // 빈 공간을 눌러도 선택되게 한다. 없으면 글자 위를 눌러야만 선택된다.
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    /// ▶ 또는 ■. 버튼 안을 누른 것은 행 선택 제스처보다 버튼이 먼저 받는다.
    @ViewBuilder private var actionButton: some View {
        switch row.action {
        case .run(let enabled):
            Button(action: onRun) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).disabled(!enabled).help(row.actionHelp ?? "")
        case .stop(let enabled):
            Button(action: onStop) { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless).disabled(!enabled).help(row.actionHelp ?? "")
        }
    }
}

/// 선택한 환경의 상세: 제목, 링 3개, 세부 건수, 안내, 실패한 테스트.
struct DetailView: View {
    let detail: EnvDetailModel
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

/// 오른쪽 칸: 소요 시간. 실행 중이면 1초마다 경과 시간을 다시 그린다.
/// TimelineView를 쓰는 이유: 실행 상태 알림은 진행이 바뀔 때만 오므로, 긴 테스트 하나가 도는 동안에는
/// 알림만으로는 시간이 멈춰 보인다.
struct ElapsedView: View {
    let text: String
    let startedAt: Date?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                if let start = startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
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
