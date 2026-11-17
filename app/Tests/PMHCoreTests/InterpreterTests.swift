import Foundation
import Testing
@testable import PMHCore

private func report(_ v: [Int] = [3, 13, 1], pytest: String? = "9.0", fastapi: String? = "0.1", plugin: Bool = true) -> CheckReport {
    CheckReport(pythonVersion: v, pytestVersion: pytest, fastapiVersion: fastapi, pluginInstalled: plugin)
}
private func codes(_ c: EnvCheck) -> [IssueCode] { c.issues.map(\.code) }

@Suite struct InterpreterTests {
    @Test func healthyIsReady() {
        let c = Interpreter.interpret(report: report(), pythonPath: "/p", repoPath: "/repo")
        #expect(c.status == .ready)
        #expect(c.issues.isEmpty)
    }

    @Test func python39IsAccepted() {
        #expect(Interpreter.interpret(report: report([3, 9, 6]), pythonPath: "/p", repoPath: nil).status == .ready)
    }

    @Test func python38IsError() {
        let c = Interpreter.interpret(report: report([3, 8, 20]), pythonPath: "/p", repoPath: nil)
        #expect(c.status == .error)
        #expect(codes(c) == [.pythonTooOld])
    }

    @Test func python2StyleLowMajorIsError() {
        #expect(Interpreter.interpret(report: report([2, 7, 18]), pythonPath: "/p", repoPath: nil).status == .error)
    }

    @Test func missingPytestIsError() {
        let c = Interpreter.interpret(report: report(pytest: nil), pythonPath: "/p", repoPath: nil)
        #expect(c.status == .error)
        #expect(codes(c) == [.pytestMissing])
    }

    @Test func missingPluginIsActionNeededWithCopyOnlyCommand() {
        let c = Interpreter.interpret(report: report(plugin: false), pythonPath: "/my venv/bin/python", repoPath: "/repo/pmh")
        #expect(c.status == .actionNeeded)
        #expect(c.issues[0].fixCommand == "uv pip install --python '/my venv/bin/python' -e /repo/pmh")
    }

    @Test func missingFastapiIsWarningOnly() {
        let c = Interpreter.interpret(report: report(fastapi: nil), pythonPath: "/p", repoPath: nil)
        #expect(c.status == .actionNeeded)
        #expect(codes(c) == [.fastapiMissing])
    }

    @Test func worstSeverityWins() {
        let c = Interpreter.interpret(report: report(pytest: nil, fastapi: nil, plugin: false), pythonPath: "/p", repoPath: nil)
        #expect(c.status == .error)
        #expect(Set(codes(c)) == [.pytestMissing, .pluginMissing, .fastapiMissing])
    }

    @Test func processFailuresAreErrors() {
        func run(exit: Int32 = 0, out: String = "", timedOut: Bool = false) -> EnvCheck {
            Interpreter.interpret(exitCode: exit, stdout: Data(out.utf8), stderr: "boom", timedOut: timedOut, pythonPath: "/p", repoPath: nil)
        }
        #expect(codes(run(exit: 1)) == [.runFailed])
        #expect(codes(run(out: "not json")) == [.invalidOutput])
        #expect(codes(run(timedOut: true)) == [.timedOut])
        #expect(run(exit: 1).status == .error)
    }

    @Test func validJsonFromScriptIsParsed() {
        let json = "{\"python_version\":[3,12,1],\"pytest_version\":\"8.4.2\",\"fastapi_version\":null,\"plugin_installed\":true}"
        let c = Interpreter.interpret(exitCode: 0, stdout: Data(json.utf8), stderr: "", timedOut: false, pythonPath: "/p", repoPath: nil)
        #expect(c.report?.pythonVersionText == "3.12.1")
        #expect(codes(c) == [.fastapiMissing])
    }

    @Test func projectSummary() {
        let ok = EnvCheck(status: .ready, report: nil, issues: [])
        let warn = EnvCheck(status: .actionNeeded, report: nil, issues: [])
        let bad = EnvCheck(status: .error, report: nil, issues: [])
        #expect(ProjectSummary.summarize([]) == .noEnvironment)
        #expect(ProjectSummary.summarize([ok, nil]) == .checking)
        #expect(ProjectSummary.summarize([ok, ok]) == .status(.ready))
        #expect(ProjectSummary.summarize([ok, warn]) == .status(.actionNeeded))
        #expect(ProjectSummary.summarize([ok, warn, bad]) == .status(.error))
    }

    @Test func shellQuoting() {
        #expect(Interpreter.shellQuote("/a/b-c_d.e") == "/a/b-c_d.e")
        #expect(Interpreter.shellQuote("/a b") == "'/a b'")
        #expect(Interpreter.shellQuote("/it's") == "'/it'\\''s'")
    }
}
