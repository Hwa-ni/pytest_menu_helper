// EnvComparison.swift
// 9단계 "환경 비교" 절(설계 docs/STEP9_DESIGN.md 3.2)이 보여 줄 값을 만드는 순수 코드. AppKit·SwiftUI를 쓰지 않는다.
// 입력: 한 프로젝트의 등록 정보(Project), 환경 검사 결과(Python 버전), 합친 실행 상태(RunSnapshot.merged의 결과:
//       환경별 마지막 결과·끝난 시각·소요 시간·출처·묶음 ID), 상세에 선택된 환경 id.
// 출력: EnvComparisonModel(열 = 환경, 행 = 테스트 하나, 칸 = 그 환경에서의 결과). 결과가 다른 테스트를 먼저 두고,
//       모두 같은 테스트는 "모두 같음 N건" 한 줄로 접는다. 실행 조건(args)이 다르면 맨 위 경고 문장을 준다.
// 규칙:
// - 없음(그 환경에서 수집되지 않음)·미실행·미완료·수집 오류는 통과로 세지 않는다. 칸 값을 그대로 비교하므로
//   한 환경은 통과, 다른 환경은 없음이면 "결과가 다름"이다.
// - 이 비교는 같은 시점의 "환경 간" 비교다. 같은 환경 안의 시간상 변화(새 실패·회복)는 11단계이며 만들지 않는다.
//   결과가 환경 id로만 저장되므로(RunSnapshot.results) 환경 B 결과가 환경 A의 회복으로 보일 경로가 없다.
// - 판정은 집계기(tests[].status, not_run, collection_errors)가 정한 값을 그대로 옮긴다. 여기서는 맞대어 보여 주기만 한다.

import Foundation

/// 비교 표의 칸 하나. 한 테스트가 한 환경에서 어떻게 끝났는지.
public enum ComparisonCell: Equatable {
    case passed, failed, error, skipped, xfailed, xpassed
    /// 일부 단계만 보고됨(집계기 status incomplete).
    case incomplete
    /// 수집됐지만 시작도 못 함(집계기 not_run).
    case notRun
    /// 그 환경에서 수집되지 않음(테스트 목록에 아예 없음).
    case absent
    /// 그 테스트의 파일이 그 환경에서 수집 오류(import 실패 등)로 빠짐.
    case collectionError
    /// 집계기가 새로 만든 모르는 status 값. 그대로 보여 주고 통과로 세지 않는다.
    case other(String)

    /// 집계기 status 문자열을 칸 값으로 바꾼다. 모르는 값은 other로 남긴다(통과로 오인하지 않게).
    public init(status: String) {
        switch status {
        case "passed": self = .passed
        case "failed": self = .failed
        case "error": self = .error
        case "skipped": self = .skipped
        case "xfailed": self = .xfailed
        case "xpassed": self = .xpassed
        case "incomplete": self = .incomplete
        default: self = .other(status)
        }
    }

    /// 칸 글자. 팝오버 세부 건수(ResultPresentation.countOrder)와 같은 말을 쓴다.
    public var label: String {
        switch self {
        case .passed: return "통과"
        case .failed: return "실패"
        case .error: return "오류"
        case .skipped: return "skip"
        case .xfailed: return "xfail"
        case .xpassed: return "xpass"
        case .incomplete: return "미완료"
        case .notRun: return "미실행"
        case .absent: return "없음"
        case .collectionError: return "수집 오류"
        case .other(let s): return s
        }
    }

    /// 칸 색 분류. 실패·오류·수집 오류는 빨강, 시작 못 함·없음은 중립, 나머지 판정 아닌 값은 주의.
    public var tone: StatusTone {
        switch self {
        case .passed: return .passed
        case .failed, .error, .collectionError: return .failed
        case .skipped, .xfailed, .xpassed, .incomplete, .other: return .attention
        case .notRun, .absent: return .idle
        }
    }
}

/// 비교 표의 열 하나(환경). 열 머리에 이름·Python 버전·출처·끝난 시각을 보인다.
public struct ComparisonColumn: Equatable, Identifiable {
    /// 환경 id.
    public var id: String
    /// 환경 이름(예: "pmh-3.9").
    public var name: String
    /// 예: "Python 3.9.21". 검사 전이면 "검사 중", 버전을 읽지 못했으면 "Python -".
    public var pythonText: String
    /// "앱" 또는 "터미널". 결과를 낸 실행의 출처다.
    public var sourceText: String
    /// 예: "14:03:12 끝남", 오늘이 아니면 "11월 16일 14:03 끝남". 끝난 시각을 모르면 "끝난 시각 모름".
    public var finishedText: String
    /// 상세에 선택된 환경인지. 화면이 열 머리를 강조할 때 쓴다.
    public var isSelected: Bool
}

/// 비교 표의 행 하나(테스트 하나 또는 수집 오류 하나).
public struct ComparisonRow: Equatable, Identifiable {
    /// 표 안에서 유일한 값. 테스트는 "nodeid#반복 번호", 수집 오류만 있는 행은 "collect:nodeid".
    public var id: String
    /// 보여 줄 이름. 반복 실행이면 "(2번째)", 수집 오류 행이면 "(수집)"을 덧붙인다.
    public var title: String
    /// 열 순서와 같은 순서의 칸.
    public var cells: [ComparisonCell]

    /// 칸 값이 하나라도 다른지. 없음·미실행과 통과도 다른 값이다.
    public var differs: Bool { Set(cells.map(\.label)).count > 1 }
}

/// "환경 비교" 절 전체 값.
public struct EnvComparisonModel: Equatable {
    /// 테스트별 결과가 있는(집계기 결과가 있는) 환경. 등록 순서. 2개 미만이면 표를 그리지 않고 notes만 보인다.
    public var columns: [ComparisonColumn]
    /// 결과가 다른 테스트(먼저 보인다). 처음 보인 순서(열 순서, 그 안에서 집계기가 준 순서)를 지킨다.
    public var differingRows: [ComparisonRow]
    /// 모든 환경에서 결과가 같은 테스트. 화면은 기본으로 "모두 같음 N건" 한 줄로 접는다.
    public var sameRows: [ComparisonRow]
    /// "함께 실행"(같은 [모두 실행] 묶음) 또는 "따로 실행 · 시작 차이 12분". 열이 2개 미만이면 nil.
    public var relationText: String?
    /// 실행 인수가 서로 다르면 표 맨 위에 보일 경고. 같거나 비교할 수 없으면 nil.
    public var warning: String?
    /// 그 밖의 안내(비교에서 뺀 환경, 실행 조건을 모르는 환경 등).
    public var notes: [String]

    /// "모두 같음 N건" 문구. 같은 테스트가 없으면 nil.
    public var sameSummary: String? { sameRows.isEmpty ? nil : "모두 같음 \(sameRows.count)건" }
}

public enum EnvComparison {
    /// 실행 인수가 다를 때의 경고 문장(설계 3.2 그대로). 테스트와 화면 확인이 이 문장을 찾는다.
    public static let argsDifferWarning = "실행 조건이 달라 일부 테스트가 빠졌을 수 있습니다"
    /// 같은 [모두 실행] 묶음으로 함께 돌린 결과끼리일 때의 문구.
    public static let togetherText = "함께 실행"
    /// 비교할 열이 2개 미만일 때의 안내.
    public static let needTwoNote = "테스트별 결과가 있는 환경이 2개 이상이어야 비교합니다."

    /// 비교 절 값을 만든다.
    /// - Parameters:
    ///   - project: 선택한 프로젝트. 이 프로젝트에 등록된 환경만 비교한다.
    ///   - checks: 환경 id → 검사 결과(열 머리의 Python 버전).
    ///   - snapshot: 합친 실행 상태. results·finishedAt·elapsed·sources·batchIDs를 읽는다.
    ///   - selectedEnvID: 상세에 선택된 환경 id(열 강조용).
    ///   - now: 끝난 시각이 오늘인지 가릴 기준 시각.
    ///   - timeZone: 시각 문구의 시간대. 테스트에서 고정하려고 받는다.
    /// - Returns: 프로젝트에 결과(종류 무관)가 있는 환경이 2개 미만이면 nil(절을 보이지 않는다).
    ///   결과는 있지만 테스트별 결과가 있는 환경이 2개 미만이면 표 없이 안내만 담는다.
    public static func build(project: Project, checks: [String: EnvCheck], snapshot: RunSnapshot,
                             selectedEnvID: String?, now: Date = Date(),
                             timeZone: TimeZone = .current) -> EnvComparisonModel? {
        let withResult = project.environments.filter { snapshot.results[$0.id] != nil }
        guard withResult.count >= 2 else { return nil }

        // 열: 집계기 결과(.finished)가 있는 환경. 그 밖의 결과(미완료·실행 오류 등)는 테스트별 결과가 없어
        // 칸을 채울 수 없다. 모든 칸을 "없음"으로 넣으면 모든 테스트가 "다름"으로 보여 진짜 차이가 묻히므로 뺀다.
        var columns: [ComparisonColumn] = []
        var summaries: [RunSummary] = []
        var excluded: [String] = []
        for env in withResult {
            guard case .finished(let summary)? = snapshot.results[env.id] else {
                let text = snapshot.results[env.id].map { ResultPresentation.outcomeStatus($0).text } ?? "-"
                excluded.append("\(env.name)(\(text))")
                continue
            }
            columns.append(column(env: env, check: checks[env.id], snapshot: snapshot,
                                  selected: env.id == selectedEnvID, now: now, timeZone: timeZone))
            summaries.append(summary)
        }
        var notes: [String] = []
        if !excluded.isEmpty {
            notes.append("테스트별 결과가 없어 비교에서 뺐습니다: \(excluded.joined(separator: ", "))")
        }
        guard columns.count >= 2 else {
            notes.append(needTwoNote)
            return EnvComparisonModel(columns: columns, differingRows: [], sameRows: [], relationText: nil,
                                      warning: nil, notes: notes)
        }

        let rows = self.rows(summaries)
        let ids = columns.map(\.id)
        let argsCheck = argsDifference(summaries.map(\.args), names: columns.map(\.name))
        if let unknown = argsCheck.unknownNote { notes.append(unknown) }
        return EnvComparisonModel(columns: columns,
                                  differingRows: rows.filter(\.differs),
                                  sameRows: rows.filter { !$0.differs },
                                  relationText: relation(envIDs: ids, snapshot: snapshot),
                                  warning: argsCheck.differ ? argsDifferWarning : nil,
                                  notes: notes)
    }

    /// 열 머리 하나를 만든다.
    static func column(env: PMHEnvironment, check: EnvCheck?, snapshot: RunSnapshot, selected: Bool,
                       now: Date, timeZone: TimeZone) -> ComparisonColumn {
        let python = check.map { c in c.pythonVersionText.map { "Python \($0)" } ?? "Python -" } ?? "검사 중"
        let source = snapshot.sources[env.id] == .terminal ? "터미널" : "앱"
        let finished = snapshot.finishedAt[env.id].map { finishedText($0, now: now, timeZone: timeZone) } ?? "끝난 시각 모름"
        return ComparisonColumn(id: env.id, name: env.name, pythonText: python, sourceText: source,
                                finishedText: finished, isSelected: selected)
    }

    /// 끝난 시각 문구. 오늘이면 "14:03:12 끝남", 아니면 "11월 16일 14:03 끝남".
    /// 날짜를 붙이는 이유: 어제 결과와 오늘 결과를 같은 시각 모양으로 보이면 같은 시점 결과로 오해한다.
    static func finishedText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm:ss" : "M월 d일 HH:mm"
        return formatter.string(from: date) + " 끝남"
    }

    /// 열마다의 칸 사전을 만들고 행으로 펼친다.
    /// - Parameter summaries: 열 순서의 집계 결과.
    /// - Returns: 처음 보인 순서의 행 전체(다름·같음을 나누기 전). 수집 오류만 있는 행은 맨 뒤.
    static func rows(_ summaries: [RunSummary]) -> [ComparisonRow] {
        // 열마다 key → 칸. key는 "nodeid#반복 번호"라 같은 nodeid를 두 번 수집한 실행도 반복끼리 맞대어 본다.
        var cellMaps: [[String: ComparisonCell]] = []
        // key → (nodeid, 반복 번호). 행 이름과 수집 오류 판정에 쓴다.
        var keyInfo: [String: (nodeid: String, occurrence: Int)] = [:]
        var order: [String] = []
        func remember(_ key: String, _ nodeid: String, _ occurrence: Int) {
            if keyInfo[key] == nil { keyInfo[key] = (nodeid, occurrence); order.append(key) }
        }
        for summary in summaries {
            var map: [String: ComparisonCell] = [:]
            // nodeid → 이 실행에서 지금까지 본 횟수. not_run에는 반복 번호가 없어서, 같은 nodeid의 몇 번째인지 여기서 센다.
            var seen: [String: Int] = [:]
            for test in summary.tests {
                let key = "\(test.nodeid)#\(test.occurrence)"
                map[key] = ComparisonCell(status: test.status)
                seen[test.nodeid] = max(seen[test.nodeid] ?? 0, test.occurrence)
                remember(key, test.nodeid, test.occurrence)
            }
            for nodeid in summary.notRun {
                // 집계기는 tests와 not_run이 겹치지 않게 준다. 그래도 같은 key가 이미 있으면 덮어쓰지 않는다
                // (실제로 보고된 결과가 "시작 못 함"보다 정확하다).
                let occurrence = (seen[nodeid] ?? 0) + 1
                seen[nodeid] = occurrence
                let key = "\(nodeid)#\(occurrence)"
                if map[key] == nil { map[key] = .notRun }
                remember(key, nodeid, occurrence)
            }
            cellMaps.append(map)
        }
        let errorSets: [[String]] = summaries.map { $0.collectionErrors.compactMap(\.nodeid) }

        var result: [ComparisonRow] = order.map { key in
            let info = keyInfo[key]!
            let cells = cellMaps.indices.map { i -> ComparisonCell in
                if let cell = cellMaps[i][key] { return cell }
                // 이 환경에 그 테스트가 없다. 그 파일이 이 환경에서 수집 오류였으면 "수집 오류", 아니면 "없음".
                // 둘을 나누는 이유: 수집 오류는 고쳐야 할 실패(import 실패)이고, 없음은 실행 조건 차이일 수 있다.
                return errorSets[i].contains { covers(error: $0, nodeid: info.nodeid) } ? .collectionError : .absent
            }
            let title = info.occurrence > 1 ? "\(info.nodeid) (\(info.occurrence)번째)" : info.nodeid
            return ComparisonRow(id: key, title: title, cells: cells)
        }
        // 어느 환경의 테스트로도 이어지지 않는 수집 오류(예: 모든 환경에서 그 파일이 import에 실패)는 따로 행을 만든다.
        // 빠뜨리면 한 환경에서만 파일 전체가 빠진 경우, 다른 환경에도 테스트가 없으면 비교 표에서 흔적이 사라진다.
        var errorOrder: [String] = []
        for errors in errorSets { for e in errors where !errorOrder.contains(e) { errorOrder.append(e) } }
        for error in errorOrder where !order.contains(where: { covers(error: error, nodeid: keyInfo[$0]!.nodeid) }) {
            let cells = errorSets.map { $0.contains(error) ? ComparisonCell.collectionError : .absent }
            result.append(ComparisonRow(id: "collect:\(error)", title: "\(error) (수집)", cells: cells))
        }
        return result
    }

    /// 수집 오류 nodeid가 테스트 nodeid를 덮는지(그 테스트가 그 오류 때문에 빠졌는지).
    /// 수집 오류 nodeid는 파일("tests/test_a.py")이나 폴더("tests"), 루트("")다.
    /// 테스트 nodeid의 파일 부분("tests/test_a.py::test_x"의 앞)과 같거나, 그 폴더 아래면 덮는다.
    /// 끝에 "/"를 붙여 비교하는 이유: "tests"가 "tests_other/test_b.py"의 앞부분으로 잘못 맞지 않게 한다.
    static func covers(error: String, nodeid: String) -> Bool {
        if error.isEmpty || error == "." { return true }
        let file = nodeid.components(separatedBy: "::").first ?? nodeid
        if file == error || nodeid == error { return true }
        let folder = error.hasSuffix("/") ? error : error + "/"
        return file.hasPrefix(folder)
    }

    /// 실행 인수 차이.
    /// - Parameters: args(열 순서의 실행 인수, nil은 모름), names(열 순서의 환경 이름).
    /// - Returns: differ(아는 값끼리 서로 다름), unknownNote(모르는 열이 있으면 그 안내).
    /// 모르는 값(nil)을 "인수 없음"([])으로 보지 않는다. 옛 결과를 []로 보면 실제로는 -k로 돌린 실행을
    /// 같은 조건이라고 잘못 말할 수 있다. 그렇다고 경고를 띄우면 조건이 같아도 늘 경고가 떠서, 따로 안내만 한다.
    static func argsDifference(_ args: [[String]?], names: [String]) -> (differ: Bool, unknownNote: String?) {
        let known = args.compactMap { $0 }
        let differ = Set(known).count > 1
        let unknown = zip(args, names).filter { $0.0 == nil }.map(\.1)
        let note = unknown.isEmpty ? nil
            : "실행 조건을 알 수 없는 결과가 있어 같은 조건인지 확인하지 못했습니다: \(unknown.joined(separator: ", "))"
        return (differ, note)
    }

    /// 비교 대상끼리의 관계 문구.
    /// - Parameters: envIDs(열의 환경 id), snapshot(묶음 ID·끝난 시각·소요 시간).
    /// - Returns: 모두 같은 묶음 ID면 "함께 실행", 아니면 "따로 실행 · 시작 차이 N분"(시작 시각을 둘 이상 모르면
    ///   "따로 실행 · 시작 시각 모름").
    /// 시작 시각은 끝난 시각에서 소요 시간을 빼서 구한다(소요 시간을 모르면 끝난 시각을 쓴다). 따로 돌린 결과는
    /// 그 사이 코드가 바뀌었을 수 있다는 뜻이라 차이를 보여 준다(설계 6절: "같은 코드" 보장은 함께 실행한 묶음뿐).
    static func relation(envIDs: [String], snapshot: RunSnapshot) -> String {
        let batches = envIDs.map { snapshot.batchIDs[$0] }
        if let first = batches.first, let id = first, batches.allSatisfy({ $0 == id }) { return togetherText }
        let starts = envIDs.compactMap { env in
            snapshot.finishedAt[env].map { $0.addingTimeInterval(-(snapshot.elapsed[env] ?? 0)) }
        }
        guard starts.count >= 2, let lo = starts.min(), let hi = starts.max() else { return "따로 실행 · 시작 시각 모름" }
        return "따로 실행 · 시작 차이 \(gapText(hi.timeIntervalSince(lo)))"
    }

    /// 시작 차이 문구. 1분 미만은 "1분 미만", 1시간 미만은 "N분", 그 이상은 "N시간 M분".
    static func gapText(_ seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0))
        if whole < 60 { return "1분 미만" }
        if whole < 3600 { return "\(whole / 60)분" }
        return "\(whole / 3600)시간 \((whole % 3600) / 60)분"
    }
}
