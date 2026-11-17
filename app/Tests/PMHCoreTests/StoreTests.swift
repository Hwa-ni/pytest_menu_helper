import Foundation
import Testing
@testable import PMHCore

func tempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pmh-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct StoreTests {
    @Test func missingFileGivesEmptyRegistryWithoutWarning() {
        let store = ProjectStore(fileURL: tempDir().appendingPathComponent("projects.json"))
        let out = store.load()
        #expect(out.registry.projects.isEmpty)
        #expect(out.warning == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = tempDir()
        let store = ProjectStore(fileURL: dir.appendingPathComponent("sub/projects.json"))
        let env = PMHEnvironment(id: "env-1", name: "pmh-3.13", pythonPath: "/x/bin/python")
        let reg = Registry(projects: [Project(path: "/work/api", environments: [env])])
        try store.save(reg)
        let out = store.load()
        #expect(out.registry == reg)
        #expect(out.warning == nil)
    }

    @Test func fileUsesDocumentedKeys() throws {
        let store = ProjectStore(fileURL: tempDir().appendingPathComponent("projects.json"))
        try store.save(Registry(projects: [Project(path: "/p", environments: [PMHEnvironment(id: "e", name: "n", pythonPath: "/py")])]))
        let text = try String(contentsOf: store.fileURL)
        #expect(text.contains("\"python_path\""))
        #expect(text.contains("\"environments\""))
    }

    @Test func brokenFileDoesNotCrashAndIsKept() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("projects.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        let store = ProjectStore(fileURL: file)
        let out = store.load()
        #expect(out.registry.projects.isEmpty)
        #expect(out.warning != nil)
        // 원본은 보존되고, 다음 저장이 깨진 파일을 덮어쓰지 않는다.
        let broken = file.appendingPathExtension("broken")
        #expect(try String(contentsOf: broken) == "{ not json")
        try store.save(Registry())
        #expect(store.load().warning == nil)
    }

    @Test func wrongShapeIsTreatedAsBroken() throws {
        let file = tempDir().appendingPathComponent("projects.json")
        try "{\"version\":1,\"projects\":[{\"path\":1}]}".write(to: file, atomically: true, encoding: .utf8)
        #expect(ProjectStore(fileURL: file).load().warning != nil)
    }

    @Test func unreadableFileGivesWarning() throws {
        let file = tempDir().appendingPathComponent("projects.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let out = ProjectStore(fileURL: file).load()
        #expect(out.registry.projects.isEmpty)
        #expect(out.warning != nil)
    }

    @Test func newerVersionIsNotOverwrittenSilently() throws {
        let file = tempDir().appendingPathComponent("projects.json")
        try "{\"version\":99,\"projects\":[]}".write(to: file, atomically: true, encoding: .utf8)
        #expect(ProjectStore(fileURL: file).load().warning != nil)
    }

    @Test func projectNameIsLastPathComponent() {
        #expect(Project(path: "/Users/a/work/my-api").name == "my-api")
        #expect(defaultEnvironmentName(forPython: "/Users/a/.venvs/pmh-3.13/bin/python") == "pmh-3.13")
    }

    @Test func candidatesFindProjectVenvAndHomeVenvs() throws {
        let home = tempDir(), project = tempDir()
        func makePython(_ base: URL, _ rel: String) throws {
            let f = base.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        try makePython(project, ".venv/bin/python")
        try makePython(home, ".venvs/b/bin/python")
        try makePython(home, ".venvs/a/bin/python")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".venvs/empty"), withIntermediateDirectories: true)
        let found = PythonCandidates.find(projectPath: project.path, homeDirectory: home.path)
        #expect(found.map(\.label) == ["프로젝트 .venv", "~/.venvs/a", "~/.venvs/b"])
    }
}
