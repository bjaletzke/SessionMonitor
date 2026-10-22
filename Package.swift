// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SessionMonitor", targets: ["SessionMonitor"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
    targets: [
        .executableTarget(name: "SessionMonitor", dependencies: [.product(name: "Markdown", package: "swift-markdown")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SessionMonitorTests", dependencies: ["SessionMonitor"], resources: [.copy("Fixtures")])
    ]
)
