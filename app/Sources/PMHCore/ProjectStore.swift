import Foundation

public struct LoadOutcome: Equatable {
    public var registry: Registry
    /// 읽기 실패·깨진 파일일 때 사용자에게 보여 줄 안내. 정상이면 nil.
    public var warning: String?
}

/// 등록 정보 파일(projects.json) 읽기·쓰기. 앱이 홈에 쓰는 유일한 파일이다.
public struct ProjectStore {
    public let fileURL: URL

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pytest-menu-helper/projects.json")
    }

    public init(fileURL: URL = ProjectStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// 어떤 경우에도 던지지 않는다. 파일이 없으면 빈 등록, 깨졌으면 빈 등록 + 안내.
    /// 깨진 파일은 지우지 않고 `projects.json.broken`으로 옮겨 둔다(다음 저장이 덮어쓰지 않도록).
    public func load() -> LoadOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return LoadOutcome(registry: Registry(), warning: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return LoadOutcome(
                registry: Registry(),
                warning: "등록 파일을 읽지 못했습니다: \(error.localizedDescription)")
        }
        do {
            let registry = try JSONDecoder().decode(Registry.self, from: data)
            if registry.version > Registry.currentVersion {
                return LoadOutcome(
                    registry: Registry(),
                    warning: "등록 파일이 더 새로운 버전(\(registry.version))입니다. 덮어쓰지 않도록 저장을 건너뜁니다.")
            }
            return LoadOutcome(registry: registry, warning: nil)
        } catch {
            let backup = fileURL.appendingPathExtension("broken")
            try? fm.removeItem(at: backup)
            let moved = (try? fm.moveItem(at: fileURL, to: backup)) != nil
            let note = moved ? "원본은 \(backup.lastPathComponent)로 옮겨 두었습니다." : "원본을 옮기지 못했습니다."
            return LoadOutcome(
                registry: Registry(),
                warning: "등록 파일이 깨져 있어 빈 목록으로 시작합니다. \(note)")
        }
    }

    public func save(_ registry: Registry) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: fileURL, options: .atomic)
    }
}
