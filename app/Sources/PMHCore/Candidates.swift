import Foundation

public struct PythonCandidate: Equatable {
    public var path: String
    public var label: String
}

/// Python 후보 자동 제안. 파일 존재만 확인하며 프로젝트 안의 코드는 읽거나 실행하지 않는다.
public enum PythonCandidates {
    public static func find(projectPath: String, homeDirectory: String = NSHomeDirectory(),
                            fileManager fm: FileManager = .default) -> [PythonCandidate] {
        var result: [PythonCandidate] = []
        let projectPy = (projectPath as NSString).appendingPathComponent(".venv/bin/python")
        if fm.isExecutableFile(atPath: projectPy) {
            result.append(PythonCandidate(path: projectPy, label: "프로젝트 .venv"))
        }
        let venvs = (homeDirectory as NSString).appendingPathComponent(".venvs")
        let names = ((try? fm.contentsOfDirectory(atPath: venvs)) ?? []).sorted()
        for name in names {
            let py = (venvs as NSString).appendingPathComponent("\(name)/bin/python")
            if fm.isExecutableFile(atPath: py) {
                result.append(PythonCandidate(path: py, label: "~/.venvs/\(name)"))
            }
        }
        return result
    }
}
