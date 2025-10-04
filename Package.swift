// swift-tools-version: 6.0
import PackageDescription

let package: Package = Package(
    name: "Wakeful",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "wakeful",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("IOKit")
            ],
        )
    ]
)