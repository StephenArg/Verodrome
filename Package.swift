// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VerodromeKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "VerodromeKit", targets: ["VerodromeKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        .package(url: "https://github.com/dimitris-c/AudioStreaming.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/DenDmitriev/DominantColors.git", from: "1.2.0"),
        .package(url: "https://github.com/chicio/ID3TagEditor.git", from: "4.5.0")
    ],
    targets: [
        .target(
            name: "VerodromeKit",
            dependencies: [
                "Alamofire",
                "AudioStreaming",
                .product(name: "Collections", package: "swift-collections"),
                "DominantColors",
                "ID3TagEditor"
            ],
            path: "VerodromeKit"
        ),
        .testTarget(
            name: "VerodromeKitTests",
            dependencies: ["VerodromeKit"],
            path: "VerodromeKitTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
