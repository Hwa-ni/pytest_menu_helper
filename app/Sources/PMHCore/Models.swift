import Foundation

/// 프로젝트에 연결된 Python 환경. `id`는 앱이 만들고 실행 때 PMH_ENV_ID로 넘길 값과 같다.
public struct PMHEnvironment: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var pythonPath: String

    public init(id: String = UUID().uuidString.lowercased(), name: String, pythonPath: String) {
        self.id = id
        self.name = name
        self.pythonPath = pythonPath
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case pythonPath = "python_path"
    }
}

public struct Project: Codable, Equatable, Identifiable {
    public var id: UUID
    public var path: String
    public var environments: [PMHEnvironment]

    public init(id: UUID = UUID(), path: String, environments: [PMHEnvironment] = []) {
        self.id = id
        self.path = path
        self.environments = environments
    }

    public var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

public struct Registry: Codable, Equatable {
    public var version: Int
    public var projects: [Project]

    public static let currentVersion = 1

    public init(version: Int = Registry.currentVersion, projects: [Project] = []) {
        self.version = version
        self.projects = projects
    }
}

/// 환경 이름 기본값: `<...>/<이름>/bin/python`이면 `<이름>`.
public func defaultEnvironmentName(forPython path: String) -> String {
    let bin = (path as NSString).deletingLastPathComponent
    let envDir = (bin as NSString).deletingLastPathComponent
    let name = (envDir as NSString).lastPathComponent
    return name.isEmpty || name == "/" ? (path as NSString).lastPathComponent : name
}
