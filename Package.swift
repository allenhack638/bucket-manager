// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BucketManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.8.10"),
        .package(url: "https://github.com/smithy-lang/smithy-swift", exact: "0.258.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1")
    ],
    targets: [
        .executableTarget(
            name: "BucketManager",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
                .product(name: "Smithy", package: "smithy-swift"),
                .product(name: "SmithyStreams", package: "smithy-swift"),
                .product(name: "ClientRuntime", package: "smithy-swift"),
                .product(name: "SmithyHTTPAPI", package: "smithy-swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "sources/BucketManager"
        )
    ]
)
