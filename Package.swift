// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OverleafDesktop",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "OverleafDesktop",
            path: "Sources/OverleafDesktop",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"]
        )
    ]
)
