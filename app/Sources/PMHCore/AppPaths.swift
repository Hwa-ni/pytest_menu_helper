// AppPaths.swift
// 앱과 pytest 플러그인이 함께 쓰는 로컬 저장 위치(이벤트 폴더, 로그 폴더)를 정하고,
// 오래된 실행 파일을 정리하는 코드를 담는다.
// 입력: 저장 기준 폴더(기본은 ~/Library/Application Support/pytest-menu-helper)와
//       그 안의 공통 설정 파일 config.json(선택, {"events_dir": "<절대 경로>"}).
// 출력: 실행 ID별 이벤트·로그 파일 경로, 설정 파일을 읽지 못했을 때의 안내 문장, 정리된 파일 이름 목록.
// 6단계: 이미 열린 다른 터미널은 앱이 정한 환경변수(PYTEST_MENU_EVENTS_DIR)를 받지 못한다.
// 그래서 앱과 플러그인이 같은 설정 파일을 같은 규칙으로 읽어 이벤트 폴더를 정한다(plugin.py의 events_dir와 같은 규칙).

import Foundation

/// 앱과 플러그인이 공유하는 로컬 저장 위치. 사용자 전용(0700)으로 만든다.
public struct AppPaths: Equatable {
    public var base: URL
    /// 공통 설정 파일이 정한 이벤트 폴더. nil이면 기본 폴더(base/events)다.
    public var eventsDirOverride: URL?
    public var eventsDir: URL { eventsDirOverride ?? base.appendingPathComponent("events", isDirectory: true) }
    public var logsDir: URL { base.appendingPathComponent("logs", isDirectory: true) }
    /// 공통 설정 파일 위치. 플러그인도 같은 위치(~/Library/Application Support/pytest-menu-helper/config.json)를 읽는다.
    public var configFile: URL { base.appendingPathComponent("config.json") }

    public init(base: URL, eventsDirOverride: URL? = nil) {
        self.base = base
        self.eventsDirOverride = eventsDirOverride
    }

    /// 기본 기준 폴더(~/Library/Application Support/pytest-menu-helper).
    public static var defaultBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pytest-menu-helper", isDirectory: true)
    }

    /// 기본 기준 폴더와 공통 설정 파일로 정한 위치. 설정 파일 안내 문장이 필요하면 resolve를 직접 부른다.
    public static var `default`: AppPaths { resolve(base: defaultBase).paths }

    /// 기준 폴더의 config.json을 읽어 이벤트 폴더를 정한다.
    /// - Parameters:
    ///   - base: 기준 폴더. 그 안의 config.json을 읽는다.
    ///   - home: "~"를 풀 때 쓸 홈 폴더. 테스트에서 바꿀 수 있게 매개변수로 둔다.
    /// - Returns: paths(정한 위치)와 warning(설정 파일이 있는데 쓸 수 없을 때의 안내, 정상이거나 파일이 없으면 nil).
    /// 규칙(플러그인과 같아야 한다): 파일이 없거나, JSON이 아니거나, 최상위가 객체가 아니거나, events_dir가
    /// 빈 문자열·문자열 아님·"~"를 풀어도 상대 경로면 기본 폴더를 쓴다. 예외를 던지지 않는다.
    /// 주의: 플러그인은 잘못된 설정을 조용히 무시하고, 앱은 같은 결론(기본 폴더)에 안내만 덧붙인다.
    /// 두 쪽이 다른 폴더를 고르면 다른 터미널의 실행이 보이지 않으므로 규칙을 바꾸면 plugin.py도 함께 고친다.
    public static func resolve(base: URL, home: String = NSHomeDirectory()) -> (paths: AppPaths, warning: String?) {
        let fallback = AppPaths(base: base)
        let file = base.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return (fallback, nil) }
        let note = "공통 설정 파일(\(file.path))의 events_dir를 쓸 수 없어 기본 이벤트 폴더를 씁니다."
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (fallback, note + " JSON 형식을 확인하세요.")
        }
        // events_dir 키가 아예 없으면 다른 설정만 담은 정상 파일로 보고 안내하지 않는다.
        guard let raw = object["events_dir"] else { return (fallback, nil) }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return (fallback, note + " 값은 절대 경로 문자열이어야 합니다.")
        }
        let expanded = expandHome(text, home: home)
        guard expanded.hasPrefix("/") else {
            return (fallback, note + " 상대 경로는 쓸 수 없습니다: \(text)")
        }
        return (AppPaths(base: base, eventsDirOverride: URL(fileURLWithPath: expanded, isDirectory: true)), nil)
    }

    /// Python의 os.path.expanduser와 같은 범위만 푼다: "~" 단독과 "~/..."만. "~user"는 풀지 않는다
    /// (플러그인은 풀 수 있지만 그 경우 상대 경로처럼 보여 앱이 거절하므로, 문서에서 쓰지 말라고 안내한다).
    static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public func eventsFile(runID: String) -> URL { eventsDir.appendingPathComponent("\(runID).jsonl") }
    public func logFile(runID: String) -> URL { logsDir.appendingPathComponent("\(runID).log") }

    public func ensureDirectories() throws {
        for dir in [base, eventsDir, logsDir] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// 오래된 실행 파일 정리. 이름이 `<uuid>.<확장자>`인 일반 파일만 지운다(다른 파일·링크·폴더는 건드리지 않는다).
public enum FileCleaner {
    public static let defaultKeep = 50

    static func isRunFile(_ name: String, ext: String) -> Bool {
        guard name.hasSuffix("." + ext) else { return false }
        let stem = String(name.dropLast(ext.count + 1))
        guard stem.count == 36, stem == stem.lowercased(), let uuid = UUID(uuidString: stem) else { return false }
        return uuid.uuidString.lowercased() == stem
    }

    /// 최신 `keep`개만 남기고 지운 파일 이름을 돌려준다. `protecting`은 항상 남긴다.
    @discardableResult
    public static func prune(directory: URL, fileExtension ext: String, keep: Int = defaultKeep,
                             protecting: Set<String> = []) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, date: Date)] = []
        for url in urls where isRunFile(url.lastPathComponent, ext: ext) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            files.append((url, v.contentModificationDate ?? .distantPast))
        }
        files.sort { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
        var removed: [String] = []
        for (index, file) in files.enumerated() where index >= keep {
            let name = file.url.lastPathComponent
            if protecting.contains(name) { continue }
            if (try? fm.removeItem(at: file.url)) != nil { removed.append(name) }
        }
        return removed
    }

    /// 이벤트·로그 폴더를 함께 정리한다.
    /// - Parameters:
    ///   - paths: 앱 데이터 폴더.
    ///   - keep: 폴더마다 남길 최신 파일 수.
    ///   - runIDs: 지우면 안 되는 실행 ID. 9단계부터 실행 중·차례 기다림인 실행 ID 전부와 방금 끝난 실행 ID를 넘긴다.
    /// 실행 중인 ID를 모두 넘겨야 하는 이유: 동시 실행 중 한 실행이 끝나 정리하면, 오래 걸려 파일 수정 시각이
    /// 오래된 다른 실행의 이벤트 파일이 최신 keep개에서 밀려 지워질 수 있다. 그러면 그 실행은 진행률과 판정을 잃는다.
    public static func pruneAll(_ paths: AppPaths, keep: Int = defaultKeep, protecting runIDs: Set<String> = []) {
        prune(directory: paths.eventsDir, fileExtension: "jsonl", keep: keep,
              protecting: Set(runIDs.map { "\($0).jsonl" }))
        prune(directory: paths.logsDir, fileExtension: "log", keep: keep,
              protecting: Set(runIDs.map { "\($0).log" }))
    }
}
