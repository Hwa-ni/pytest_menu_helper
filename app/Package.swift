// swift-tools-version:5.9
import PackageDescription

// 로직은 PMHCore(테스트 가능), 화면은 PMHApp(AppKit)만 둔다.
// pmh-check는 같은 PMHCore로 환경을 검사해 표로 보여 주는 개발용 명령줄 도구다.
let package = Package(
    name: "PytestMenuHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PMHCore"),
        .executableTarget(name: "PMHApp", dependencies: ["PMHCore"]),
        .executableTarget(name: "pmh-check", dependencies: ["PMHCore"]),
        .testTarget(name: "PMHCoreTests", dependencies: ["PMHCore"]),
    ]
)
