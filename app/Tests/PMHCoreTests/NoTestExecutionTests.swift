import Foundation
import Testing
@testable import PMHCore

/// 앱이 프로젝트를 "검사만" 하고 테스트를 실행하지 않음을 보이는 테스트.
final class RecordingRunner: ProcessRunning {
    var calls: [(executable: String, arguments: [String], cwd: String, timeout: TimeInterval)] = []
    func run(executable: String, arguments: [String], workingDirectory: String, timeout: TimeInterval) -> ProcessOutput {
        calls.append((executable, arguments, workingDirectory, timeout))
        let json = "{\"python_version\":[3,13,1],\"pytest_version\":\"9\",\"fastapi_version\":\"1\",\"plugin_installed\":true,\"plugin_version\":\"0.3.0\"}"
        return ProcessOutput(exitCode: 0, stdout: Data(json.utf8), stderr: "", timedOut: false)
    }
}

@Suite struct NoTestExecutionTests {
    @Test func checkerRunsOnlyIsolatedScriptOnceWithTimeout() throws {
        let dir = tempDir()
        let py = dir.appendingPathComponent("python")
        try "#!/bin/sh\n".write(to: py, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
        let runner = RecordingRunner()
        _ = EnvironmentChecker(runner: runner).check(pythonPath: py.path)
        #expect(runner.calls.count == 1)
        let call = runner.calls[0]
        #expect(call.executable == py.path)
        #expect(call.arguments == ["-I", "-c", EnvironmentChecker.script]) // pytest 인수·-m pytest 없음
        #expect(call.cwd == "/")                                            // 프로젝트 폴더에서 실행하지 않음
        #expect(call.timeout == 10)
    }

    @Test func scriptNeverImportsPytestOrRunsAnything() {
        let s = EnvironmentChecker.script
        for forbidden in ["import pytest", "pytest.main", "subprocess", "os.system", "exec(", "eval(", "__import__", "runpy"] {
            #expect(!s.contains(forbidden), "스크립트에 \(forbidden)가 있으면 안 됩니다")
        }
        #expect(s.contains("metadata.version"))
    }

    @Test func missingOrNonExecutablePathNeverReachesRunner() throws {
        let runner = RecordingRunner()
        let checker = EnvironmentChecker(runner: runner)
        #expect(checker.check(pythonPath: "/no/such/python").issues.first?.code == .pathMissing)
        let dir = tempDir()
        #expect(checker.check(pythonPath: dir.path).issues.first?.code == .notExecutable) // 폴더
        let plain = dir.appendingPathComponent("python")
        try "x".write(to: plain, atomically: true, encoding: .utf8) // 실행 권한 없음
        #expect(checker.check(pythonPath: plain.path).issues.first?.code == .notExecutable)
        #expect(runner.calls.isEmpty)
    }

    /// 실제 Python으로: 프로젝트 폴더에 "실행되면 표지 파일을 만드는" conftest/테스트/sitecustomize가 있어도
    /// 검사가 끝난 뒤 표지 파일이 없어야 한다(= 프로젝트 코드가 import·실행되지 않았다).
    @Test func realPythonDoesNotExecuteProjectCode() throws {
        let python = NSHomeDirectory() + "/.venvs/pmh-3.13/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { return } // 환경이 없으면 건너뜀(아래 표 참고)
        let project = tempDir()
        let marker = project.appendingPathComponent("EXECUTED")
        let payload = "open(\(String(reflecting: marker.path)), 'w').write('x')\n"
        for name in ["conftest.py", "test_marker.py", "sitecustomize.py", "usercustomize.py", "pytest.py", "importlib.py", "json.py"] {
            try payload.write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // 작업 폴더가 프로젝트여도(최악의 경우) -I 때문에 import되지 않아야 한다.
        let out = SystemProcessRunner().run(executable: python, arguments: EnvironmentChecker.arguments(),
                                            workingDirectory: project.path, timeout: 10)
        #expect(out.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".pytest_cache").path))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("__pycache__").path))
        #expect(try JSONDecoder().decode(CheckReport.self, from: out.stdout).pytestVersion != nil)
    }

    @Test func realRunnerTimesOutAndDoesNotBlockForever() throws {
        let dir = tempDir()
        let slow = dir.appendingPathComponent("slow")
        try "#!/bin/sh\nsleep 30\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let start = Date()
        let out = SystemProcessRunner().run(executable: slow.path, arguments: [], workingDirectory: "/", timeout: 1)
        #expect(out.timedOut)
        #expect(Date().timeIntervalSince(start) < 8)
        let c = Interpreter.interpret(exitCode: out.exitCode, stdout: out.stdout, stderr: out.stderr, timedOut: out.timedOut, pythonPath: slow.path, repoPath: nil)
        #expect(c.issues.first?.code == .timedOut)
    }

    @Test func candidateDiscoveryOnlyListsFiles() throws {
        // 후보 탐색은 존재만 확인한다: 프로젝트 안의 python이 실행되지 않음을 표지 파일로 확인.
        let project = tempDir()
        let marker = project.appendingPathComponent("RAN")
        let py = project.appendingPathComponent(".venv/bin/python")
        try FileManager.default.createDirectory(at: py.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: py, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
        let found = PythonCandidates.find(projectPath: project.path, homeDirectory: tempDir().path)
        #expect(found.count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
