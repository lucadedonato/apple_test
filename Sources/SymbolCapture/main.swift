import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case symbolNotFound(String)
    case renderFailed(String)

    var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .symbolNotFound(let name): return "SF Symbol not found: \(name)"
        case .renderFailed(let message): return message
        }
    }
}

struct Config {
    let symbol: String
    let effect: String
    let target: String?
    let duration: Double
    let fps: Int
    let size: Int
    let output: URL

    static func parse() throws -> Config {
        var args = Array(CommandLine.arguments.dropFirst())
        var values: [String: String] = [:]

        while !args.isEmpty {
            let key = args.removeFirst()
            guard key.hasPrefix("--"), !args.isEmpty else {
                throw CaptureError.invalidArguments("Expected --key value arguments.")
            }
            values[String(key.dropFirst(2))] = args.removeFirst()
        }

        guard let symbol = values["symbol"], !symbol.isEmpty else {
            throw CaptureError.invalidArguments("Missing --symbol.")
        }

        let effect = values["effect"] ?? "wiggle"
        let target = values["target"].flatMap { $0.isEmpty ? nil : $0 }
        let duration = Double(values["duration"] ?? "2.0") ?? 2.0
        let fps = Int(values["fps"] ?? "60") ?? 60
        let size = Int(values["size"] ?? "256") ?? 256
        let output = URL(fileURLWithPath: values["output"] ?? "capture", isDirectory: true)

        guard duration > 0, fps > 0, size > 0 else {
            throw CaptureError.invalidArguments("duration, fps and size must be positive.")
        }

        return Config(
            symbol: symbol,
            effect: effect,
            target: target,
            duration: duration,
            fps: fps,
            size: size,
            output: output
        )
    }
}

@MainActor
final class SymbolCapture {
    private let config: Config
    private let app: NSApplication
    private let window: NSWindow
    private let imageView: NSImageView
    private let pointConfiguration: NSImage.SymbolConfiguration

    init(config: Config) throws {
        self.config = config
        self.app = NSApplication.shared

        app.setActivationPolicy(.prohibited)
        app.finishLaunching()

        let pointSize = CGFloat(config.size) * 0.58
        self.pointConfiguration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .regular
        )

        guard
            let base = NSImage(
                systemSymbolName: config.symbol,
                accessibilityDescription: nil
            ),
            let image = base.withSymbolConfiguration(pointConfiguration)
        else {
            throw CaptureError.symbolNotFound(config.symbol)
        }

        let frame = NSRect(
            x: 0,
            y: 0,
            width: config.size,
            height: config.size
        )

        let root = NSView(frame: frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        self.imageView = NSImageView(frame: frame)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.contentTintColor = .black
        imageView.wantsLayer = true
        root.addSubview(imageView)

        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = root
        window.setFrameOrigin(NSPoint(x: 120, y: 120))
        window.orderFrontRegardless()

        app.activate(ignoringOtherApps: true)
        runLoop(for: 0.25)
    }

    func run() throws {
        try FileManager.default.createDirectory(
            at: config.output,
            withIntermediateDirectories: true
        )

        let framesURL = config.output.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(
            at: framesURL,
            withIntermediateDirectories: true
        )

        if config.effect == "variableDraw" {
            try captureVariableDraw(to: framesURL)
        } else {
            try applyEffect()
            try captureTimedFrames(to: framesURL)
        }

        try writeManifest()

        window.orderOut(nil)
        app.stop(nil)
    }

    private func applyEffect() throws {
        let options: SymbolEffectOptions = .nonRepeating

        switch config.effect {
        case "bounce":
            imageView.addSymbolEffect(.bounce, options: options)

        case "pulse":
            imageView.addSymbolEffect(.pulse, options: options)

        case "variableColor":
            imageView.addSymbolEffect(.variableColor.iterative, options: options)

        case "scale":
            imageView.addSymbolEffect(.scale.up, options: options)

        case "appear":
            imageView.addSymbolEffect(.appear, options: options)

        case "disappear":
            imageView.addSymbolEffect(.disappear, options: options)

        case "wiggle":
            imageView.addSymbolEffect(.wiggle, options: options)

        case "rotate":
            imageView.addSymbolEffect(.rotate, options: options)

        case "breathe":
            imageView.addSymbolEffect(.breathe, options: options)

        case "drawOn":
            imageView.addSymbolEffect(.drawOn.byLayer, options: options)

        case "drawOff":
            imageView.addSymbolEffect(.drawOff.byLayer, options: options)

        case "replace":
            guard let targetName = config.target, !targetName.isEmpty else {
                throw CaptureError.invalidArguments(
                    "Effect 'replace' requires --target."
                )
            }

            guard
                let base = NSImage(
                    systemSymbolName: targetName,
                    accessibilityDescription: nil
                ),
                let targetImage = base.withSymbolConfiguration(pointConfiguration)
            else {
                throw CaptureError.symbolNotFound(targetName)
            }

            // On current Apple runtimes, .replace uses Apple's context-sensitive
            // Replace behavior, including Magic Replace where the pair supports it.
            imageView.setSymbolImage(
                targetImage,
                contentTransition: .replace,
                options: .default
            )

        case "replaceDownUp":
            try replace(using: .replace.downUp)

        case "replaceUpUp":
            try replace(using: .replace.upUp)

        case "replaceOffUp":
            try replace(using: .replace.offUp)

        default:
            throw CaptureError.invalidArguments(
                "Unknown effect: \(config.effect)"
            )
        }
    }

    private func replace<T>(
        using transition: T
    ) throws where T: ContentTransitionSymbolEffect & SymbolEffect {
        guard let targetName = config.target, !targetName.isEmpty else {
            throw CaptureError.invalidArguments(
                "Replace effects require --target."
            )
        }

        guard
            let base = NSImage(
                systemSymbolName: targetName,
                accessibilityDescription: nil
            ),
            let targetImage = base.withSymbolConfiguration(pointConfiguration)
        else {
            throw CaptureError.symbolNotFound(targetName)
        }

        imageView.setSymbolImage(
            targetImage,
            contentTransition: transition,
            options: .default
        )
    }

    private func captureTimedFrames(to framesURL: URL) throws {
        let frameCount = max(1, Int(ceil(config.duration * Double(config.fps))))
        let start = Date()

        for index in 0..<frameCount {
            let targetTime = start.addingTimeInterval(
                Double(index) / Double(config.fps)
            )

            while Date() < targetTime {
                RunLoop.main.run(
                    mode: .default,
                    before: targetTime
                )
            }

            imageView.layer?.displayIfNeeded()

            let url = framesURL.appendingPathComponent(
                String(format: "frame_%05d.png", index)
            )

            try capturePNG(to: url)
        }
    }

    private func captureVariableDraw(to framesURL: URL) throws {
        let frameCount = max(2, Int(ceil(config.duration * Double(config.fps))))

        let mode = NSImage.SymbolConfiguration(
            variableValueMode: .draw
        )

        let combined = pointConfiguration.applying(mode)

        for index in 0..<frameCount {
            let progress = Double(index) / Double(frameCount - 1)

            guard
                let base = NSImage(
                    systemSymbolName: config.symbol,
                    variableValue: progress,
                    accessibilityDescription: nil
                ),
                let image = base.withSymbolConfiguration(combined)
            else {
                throw CaptureError.symbolNotFound(config.symbol)
            }

            imageView.image = image
            imageView.needsDisplay = true
            imageView.layer?.displayIfNeeded()
            runLoop(for: 0.001)

            let url = framesURL.appendingPathComponent(
                String(format: "frame_%05d.png", index)
            )

            try capturePNG(to: url)
        }
    }

    private func capturePNG(to url: URL) throws {
        guard let layer = imageView.layer else {
            throw CaptureError.renderFailed("NSImageView has no backing layer.")
        }

        let width = config.size
        let height = config.size
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.renderFailed("Could not create CGContext.")
        }

        context.clear(
            CGRect(x: 0, y: 0, width: width, height: height)
        )

        layer.render(in: context)

        guard let image = context.makeImage() else {
            throw CaptureError.renderFailed("Could not create CGImage.")
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptureError.renderFailed("Could not create PNG destination.")
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.renderFailed("Could not write PNG: \(url.path)")
        }
    }

    private func writeManifest() throws {
        let process = ProcessInfo.processInfo
        let manifest: [String: Any] = [
            "symbol": config.symbol,
            "effect": config.effect,
            "target": config.target as Any,
            "duration": config.duration,
            "fps": config.fps,
            "size": config.size,
            "frameCount": max(1, Int(ceil(config.duration * Double(config.fps)))),
            "osVersion": process.operatingSystemVersionString,
            "source": "Apple AppKit/Symbols runtime",
            "officialRuntime": true,
            "inventedAnimation": false
        ]

        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(
            to: config.output.appendingPathComponent("manifest.json")
        )
    }

    private func runLoop(for seconds: Double) {
        let until = Date().addingTimeInterval(seconds)

        while Date() < until {
            RunLoop.main.run(
                mode: .default,
                before: until
            )
        }
    }
}

@main
struct Main {
    @MainActor
    static func main() {
        do {
            let config = try Config.parse()
            let capture = try SymbolCapture(config: config)
            try capture.run()
            print("CAPTURE_OK")
            print("symbol=\(config.symbol)")
            print("effect=\(config.effect)")
            print("output=\(config.output.path)")
        } catch {
            fputs("CAPTURE_ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}
