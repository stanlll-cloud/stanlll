// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonyRecipeStudio",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SonyRecipeStudio", targets: ["SonyRecipeStudio"])],
    targets: [
        .executableTarget(
            name: "SonyRecipeStudio",
            path: "Sources/SonyRecipeStudio"
        )
    ]
)