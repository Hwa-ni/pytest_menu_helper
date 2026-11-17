import Foundation

/// 프로세스 실행을 끼워 넣을 수 있게 분리(테스트에서 실제 Python 없이 인수를 확인한다).
public protocol ProcessRunning {
    func run(executable: String, arguments: [String], workingDirectory: String, timeout: TimeInterval)
        -> ProcessOutput
}

public struct ProcessOutput {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: String
    public var timedOut: Bool
    public init(exitCode: Int32, stdout: Data, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], workingDirectory: String,
                    timeout: TimeInterval) -> ProcessOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return ProcessOutput(exitCode: 127, stdout: Data(), stderr: "\(error)", timedOut: false)
        }
        // 파이프가 가득 차 자식이 멈추지 않도록 별도 큐에서 끝까지 읽는다.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); exited.signal() }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 3)
        return ProcessOutput(exitCode: p.terminationStatus, stdout: outData,
                             stderr: String(data: errData, encoding: .utf8) ?? "", timedOut: timedOut)
    }
}

/// 선택한 Python으로 작은 스크립트를 1번 실행해 환경 정보를 JSON으로 받는다.
/// pytest를 실행하지 않고, 프로젝트 코드를 import하지 않는다(`-I`, 작업 폴더는 `/`).
public struct EnvironmentChecker {
    public static let timeout: TimeInterval = 10
    public static let pluginEntryPointName = "pytest_menu_helper.plugin"

    /// 메타데이터(dist-info)만 읽는다. pytest·fastapi도 import하지 않는다.
    public static let script = """
    import json, sys
    from importlib import metadata
    def ver(name):
        try:
            return metadata.version(name)
        except Exception:
            return None
    plugin = False
    for dist in metadata.distributions():
        for ep in dist.entry_points:
            if ep.group == "pytest11" and ep.name == "\(pluginEntryPointName)":
                plugin = True
    print(json.dumps({
        "python_version": list(sys.version_info[:3]),
        "pytest_version": ver("pytest"),
        "fastapi_version": ver("fastapi"),
        "plugin_installed": plugin,
        "plugin_version": ver("pytest-menu-helper"),
    }))
    """

    public static func arguments() -> [String] { ["-I", "-c", script] }

    let runner: ProcessRunning
    let repoPath: String?
    let fileManager: FileManager

    public init(runner: ProcessRunning = SystemProcessRunner(), repoPath: String? = nil,
                fileManager: FileManager = .default) {
        self.runner = runner
        self.repoPath = repoPath
        self.fileManager = fileManager
    }

    /// 동기 검사. 메인 스레드에서 부르지 말고 `checkAsync`를 쓴다.
    public func check(pythonPath: String) -> EnvCheck {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: pythonPath, isDirectory: &isDir) else {
            return Interpreter.pathFailure(.pathMissing, path: pythonPath)
        }
        guard !isDir.boolValue, fileManager.isExecutableFile(atPath: pythonPath) else {
            return Interpreter.pathFailure(.notExecutable, path: pythonPath)
        }
        let out = runner.run(executable: pythonPath, arguments: Self.arguments(),
                             workingDirectory: "/", timeout: Self.timeout)
        return Interpreter.interpret(exitCode: out.exitCode, stdout: out.stdout, stderr: out.stderr,
                                     timedOut: out.timedOut, pythonPath: pythonPath, repoPath: repoPath)
    }

    /// 백그라운드에서 검사하고 결과는 메인 큐로 돌려준다(메인 스레드를 막지 않는다).
    public func checkAsync(pythonPath: String, completion: @escaping (EnvCheck) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.check(pythonPath: pythonPath)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
