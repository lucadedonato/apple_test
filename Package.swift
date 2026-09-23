// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SFSymbolCapture",
    products: [
        .executable(name: "symbol-capture", targets: ["SymbolCapture"])
    ],
    targets: [
        .executableTarget(name: "SymbolCapture")
    ]
)
