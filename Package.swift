// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingSidekickfree",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetingSidekickfree", targets: ["MeetingSidekickfree"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingSidekickfree",
            path: "Sources/MeetingSidekick"
        )
    ]
)
