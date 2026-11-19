// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DisplayControl",
    platforms: [.macOS(.v26)],
    targets: [
        // 単一の実行ターゲット。画面通信・UI・統合のソースはすべてここに入る。
        .executableTarget(
            name: "DisplayControl",
            path: "Sources/DisplayControl"
        ),
        .testTarget(
            name: "DisplayControlTests",
            dependencies: ["DisplayControl"],
            path: "Tests/DisplayControlTests"
        ),
    ]
)
