// AppPaths.swift
// 앱과 pytest 플러그인이 함께 쓰는 로컬 저장 위치(이벤트 폴더, 로그 폴더)를 정하고,
// 오래된 실행 파일을 정리하는 코드를 담는다.
// 입력: 저장 기준 폴더(기본은 ~/Library/Application Support/pytest-menu-helper).
// 출력: 실행 ID별 이벤트·로그 파일 경로, 정리된 파일 이름 목록.

import Foundation

/// 앱과 플러그인이 공유하는 로컬 저장 위치. 사용자 전용(0700)으로 만든다.
public struct AppPaths: Equatable {
    public var base: URL
    public var eventsDir: URL { base.appendingPathComponent("events", isDirectory: true) }
    public var logsDir: URL { base.appendingPathComponent("logs", isDirectory: true) }

    public init(base: URL) { self.base = base }

    public static var `default`: AppPaths {
        AppPaths(base: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pytest-menu-helper", isDirectory: true))
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

    public static func pruneAll(_ paths: AppPaths, keep: Int = defaultKeep, protectingRunID: String? = nil) {
        prune(directory: paths.eventsDir, fileExtension: "jsonl", keep: keep,
              protecting: protectingRunID.map { ["\($0).jsonl"] } ?? [])
        prune(directory: paths.logsDir, fileExtension: "log", keep: keep,
              protecting: protectingRunID.map { ["\($0).log"] } ?? [])
    }
}
