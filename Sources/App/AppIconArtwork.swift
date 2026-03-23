import AppKit
import SwiftUI

@MainActor
enum AppIconArtwork {
    static let appIcon: NSImage = IconRenderer.makeAppIcon()

    static let menuBarIcon: NSImage = {
        let image = IconRenderer.makeMenuBarIcon()
        image.isTemplate = false
        image.size = NSSize(width: 20, height: 20)
        return image
    }()

    static func applyApplicationIcon() {
        NSApp.applicationIconImage = appIcon
    }

    static func exportAssets(to directoryURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        try writePNG(appIcon, to: directoryURL.appending(path: "AppIcon-master.png"))
        try writePNG(menuBarIcon, to: directoryURL.appending(path: "MenuBarIcon-template.png"))
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw IconExportError.failedToEncodePNG(url.lastPathComponent)
        }

        try pngData.write(to: url, options: .atomic)
    }
}

@MainActor
struct MenuBarStatusIcon: View {
    var body: some View {
        Image(nsImage: AppIconArtwork.menuBarIcon)
            .renderingMode(.original)
            .frame(width: 20, height: 20)
            .accessibilityLabel(L10n.tr("Codex Account Switcher"))
            .help(L10n.tr("Codex Account Switcher"))
    }
}

struct IconExportRequest {
    let outputDirectory: URL

    static var current: IconExportRequest? {
        let arguments = CommandLine.arguments

        guard let flagIndex = arguments.firstIndex(of: "--export-icons") else {
            return nil
        }

        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        let outputPath = arguments[valueIndex]
        return IconExportRequest(outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true))
    }
}

enum IconExportError: LocalizedError {
    case failedToEncodePNG(String)

    var errorDescription: String? {
        switch self {
        case .failedToEncodePNG(let filename):
            L10n.tr("无法编码 PNG: %@", filename)
        }
    }
}

private enum IconRenderer {
    private enum ArrowDirection {
        case left
        case right
    }

    private enum TileBackgroundStyle {
        case dark
        case light
    }

    static func makeAppIcon() -> NSImage {
        makeImage(pixelWidth: 1024, pixelHeight: 1024) { rect in
            drawAppIcon(in: rect)
        }
    }

    static func makeMenuBarIcon() -> NSImage {
        makeImage(pixelWidth: 72, pixelHeight: 72) { rect in
            drawMenuBarIcon(in: rect.insetBy(dx: 2, dy: 2))
        }
    }

    private static func makeImage(
        pixelWidth: Int,
        pixelHeight: Int,
        drawing: (CGRect) -> Void
    ) -> NSImage {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
        }

        bitmap.size = NSSize(width: pixelWidth, height: pixelHeight)

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.setShouldAntialias(true)

        NSGraphicsContext.saveGraphicsState()
        drawing(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.current = previousContext

        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func drawAppIcon(in rect: CGRect) {
        drawBrandedIcon(in: rect, backgroundStyle: .dark)
    }

    private static func drawMenuBarIcon(in rect: CGRect) {
        drawBrandedIcon(in: rect, backgroundStyle: .light)
    }

    private static func drawBrandedIcon(in rect: CGRect, backgroundStyle: TileBackgroundStyle) {
        let tileRect = rect.insetBy(dx: rect.width * 0.085, dy: rect.height * 0.085)
        let tileRadius = tileRect.width * 0.23
        let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)

        switch backgroundStyle {
        case .dark:
            withShadow(color: NSColor.black.withAlphaComponent(0.28), blur: 28, offset: NSSize(width: 0, height: -10)) {
                NSColor(hex: 0x081018).setFill()
                tilePath.fill()
            }

            tilePath.addClip()
            NSGradient(colors: [
                NSColor(hex: 0x081522),
                NSColor(hex: 0x0D2B42),
                NSColor(hex: 0x0E5B73),
            ])?.draw(in: tilePath, angle: -36)

        case .light:
            withShadow(color: NSColor.black.withAlphaComponent(0.16), blur: rect.width * 0.06, offset: NSSize(width: 0, height: -2)) {
                NSColor.white.setFill()
                tilePath.fill()
            }

            tilePath.addClip()
            NSGradient(colors: [
                NSColor.white,
                NSColor(hex: 0xF5F8FC),
            ])?.draw(in: tilePath, angle: 90)
        }

        drawGlow(
            center: CGPoint(x: tileRect.minX + tileRect.width * 0.28, y: tileRect.maxY - tileRect.height * 0.22),
            radius: tileRect.width * 0.42,
            color: NSColor(hex: 0x8EF7D5, alpha: 0.18)
        )
        drawGlow(
            center: CGPoint(x: tileRect.maxX - tileRect.width * 0.18, y: tileRect.minY + tileRect.height * 0.2),
            radius: tileRect.width * 0.38,
            color: NSColor(hex: 0x4ED8FF, alpha: 0.18)
        )

        drawGrid(in: tileRect.insetBy(dx: tileRect.width * 0.06, dy: tileRect.height * 0.06), clipPath: tilePath)

        let backCard = CGRect(
            x: tileRect.minX + tileRect.width * 0.14,
            y: tileRect.midY + tileRect.height * 0.025,
            width: tileRect.width * 0.42,
            height: tileRect.height * 0.28
        )
        let frontCard = CGRect(
            x: tileRect.midX + tileRect.width * 0.01,
            y: tileRect.minY + tileRect.height * 0.18,
            width: tileRect.width * 0.42,
            height: tileRect.height * 0.28
        )
        let switchPanel = CGRect(
            x: tileRect.midX - tileRect.width * 0.235,
            y: tileRect.midY - tileRect.height * 0.14,
            width: tileRect.width * 0.47,
            height: tileRect.height * 0.28
        )

        drawCard(
            in: backCard,
            fillColors: [
                NSColor(hex: 0xD7F8FF, alpha: 0.28),
                NSColor(hex: 0xA7F0FF, alpha: 0.12),
            ],
            stroke: NSColor.white.withAlphaComponent(0.18),
            avatar: NSColor(hex: 0x8EF7D5, alpha: 0.86),
            text: NSColor.white.withAlphaComponent(0.24)
        )

        drawCard(
            in: frontCard,
            fillColors: [
                NSColor(hex: 0xFBFDFF),
                NSColor(hex: 0xDCF4FF),
            ],
            stroke: NSColor.white.withAlphaComponent(0.5),
            avatar: NSColor(hex: 0x4ED8FF),
            text: NSColor(hex: 0x17364B, alpha: 0.22)
        )

        drawSwitchPanel(in: switchPanel)

        let borderPath = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1, dy: 1), xRadius: tileRadius - 1, yRadius: tileRadius - 1)
        switch backgroundStyle {
        case .dark:
            NSColor.white.withAlphaComponent(0.08).setStroke()
        case .light:
            NSColor.black.withAlphaComponent(0.08).setStroke()
        }
        borderPath.lineWidth = 2
        borderPath.stroke()
    }

    private static func drawGrid(in rect: CGRect, clipPath: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()

        let lineColor = NSColor.white.withAlphaComponent(0.08)
        lineColor.setStroke()

        let gridPath = NSBezierPath()
        gridPath.lineWidth = 1

        let step = rect.width / 8
        for index in 0 ... 8 {
            let x = rect.minX + CGFloat(index) * step
            gridPath.move(to: CGPoint(x: x, y: rect.minY))
            gridPath.line(to: CGPoint(x: x, y: rect.maxY))

            let y = rect.minY + CGFloat(index) * step
            gridPath.move(to: CGPoint(x: rect.minX, y: y))
            gridPath.line(to: CGPoint(x: rect.maxX, y: y))
        }

        gridPath.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCard(
        in rect: CGRect,
        fillColors: [NSColor],
        stroke: NSColor,
        avatar: NSColor,
        text: NSColor
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.18, yRadius: rect.height * 0.18)

        withShadow(color: NSColor.black.withAlphaComponent(0.14), blur: 22, offset: NSSize(width: 0, height: -10)) {
            path.addClip()
            NSGradient(colors: fillColors)?.draw(in: path, angle: 90)
        }

        stroke.setStroke()
        path.lineWidth = 2
        path.stroke()

        let avatarRect = CGRect(
            x: rect.minX + rect.width * 0.1,
            y: rect.maxY - rect.height * 0.31,
            width: rect.height * 0.16,
            height: rect.height * 0.16
        )
        let avatarPath = NSBezierPath(ovalIn: avatarRect)
        avatar.setFill()
        avatarPath.fill()

        let primaryBar = CGRect(
            x: avatarRect.maxX + rect.width * 0.045,
            y: avatarRect.minY + rect.height * 0.02,
            width: rect.width * 0.42,
            height: rect.height * 0.08
        )
        let secondaryBar = CGRect(
            x: rect.minX + rect.width * 0.1,
            y: rect.minY + rect.height * 0.23,
            width: rect.width * 0.54,
            height: rect.height * 0.07
        )
        let tertiaryBar = CGRect(
            x: rect.minX + rect.width * 0.1,
            y: rect.minY + rect.height * 0.12,
            width: rect.width * 0.32,
            height: rect.height * 0.07
        )

        fillRoundedRect(primaryBar, radius: primaryBar.height / 2, color: text)
        fillRoundedRect(secondaryBar, radius: secondaryBar.height / 2, color: text)
        fillRoundedRect(tertiaryBar, radius: tertiaryBar.height / 2, color: text.withAlphaComponent(text.alphaComponent * 0.8))
    }

    private static func drawSwitchPanel(in rect: CGRect) {
        let panelPath = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.28, yRadius: rect.height * 0.28)

        withShadow(color: NSColor.black.withAlphaComponent(0.3), blur: 26, offset: NSSize(width: 0, height: -12)) {
            panelPath.addClip()
            NSGradient(colors: [
                NSColor(hex: 0x0C1521, alpha: 0.92),
                NSColor(hex: 0x13253A, alpha: 0.9),
            ])?.draw(in: panelPath, angle: 90)
        }

        let glowRect = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.08)
        drawGlow(center: CGPoint(x: glowRect.minX + glowRect.width * 0.2, y: glowRect.maxY), radius: rect.width * 0.36, color: NSColor(hex: 0x8EF7D5, alpha: 0.18))
        drawGlow(center: CGPoint(x: glowRect.maxX, y: glowRect.minY), radius: rect.width * 0.34, color: NSColor(hex: 0x4ED8FF, alpha: 0.18))

        NSColor.white.withAlphaComponent(0.1).setStroke()
        panelPath.lineWidth = 2
        panelPath.stroke()

        let arrowHeight = rect.height * 0.16
        let topArrow = CGRect(
            x: rect.minX + rect.width * 0.14,
            y: rect.midY + rect.height * 0.1,
            width: rect.width * 0.7,
            height: arrowHeight
        )
        let bottomArrow = CGRect(
            x: rect.minX + rect.width * 0.16,
            y: rect.midY - rect.height * 0.26,
            width: rect.width * 0.7,
            height: arrowHeight
        )

        drawArrow(
            in: topArrow,
            direction: .right,
            fillColors: [NSColor(hex: 0x8EF7D5), NSColor(hex: 0x52D5FF)]
        )
        drawArrow(
            in: bottomArrow,
            direction: .left,
            fillColors: [NSColor(hex: 0x52D5FF), NSColor(hex: 0xB3FFF1)]
        )

        let dividerRect = CGRect(
            x: rect.minX + rect.width * 0.12,
            y: rect.midY - rect.height * 0.02,
            width: rect.width * 0.76,
            height: 2
        )
        fillRoundedRect(dividerRect, radius: 1, color: NSColor.white.withAlphaComponent(0.08))
    }

    private static func drawArrow(in rect: CGRect, direction: ArrowDirection, fillColors: [NSColor]) {
        let headWidth = rect.height * 1.18
        let shaftInset = rect.height * 0.2
        let shaftRect: CGRect
        let arrowPath = NSBezierPath()

        switch direction {
        case .right:
            shaftRect = CGRect(
                x: rect.minX,
                y: rect.minY + shaftInset,
                width: rect.width - headWidth,
                height: rect.height - shaftInset * 2
            )

            arrowPath.appendRoundedRect(shaftRect, xRadius: shaftRect.height / 2, yRadius: shaftRect.height / 2)
            arrowPath.move(to: CGPoint(x: shaftRect.maxX - shaftRect.height * 0.4, y: rect.maxY))
            arrowPath.line(to: CGPoint(x: rect.maxX, y: rect.midY))
            arrowPath.line(to: CGPoint(x: shaftRect.maxX - shaftRect.height * 0.4, y: rect.minY))
            arrowPath.close()

        case .left:
            shaftRect = CGRect(
                x: rect.minX + headWidth,
                y: rect.minY + shaftInset,
                width: rect.width - headWidth,
                height: rect.height - shaftInset * 2
            )

            arrowPath.appendRoundedRect(shaftRect, xRadius: shaftRect.height / 2, yRadius: shaftRect.height / 2)
            arrowPath.move(to: CGPoint(x: shaftRect.minX + shaftRect.height * 0.4, y: rect.maxY))
            arrowPath.line(to: CGPoint(x: rect.minX, y: rect.midY))
            arrowPath.line(to: CGPoint(x: shaftRect.minX + shaftRect.height * 0.4, y: rect.minY))
            arrowPath.close()
        }

        withShadow(color: fillColors.last?.withAlphaComponent(0.35) ?? .clear, blur: rect.height * 0.8, offset: .zero) {
            arrowPath.addClip()
            let angle: CGFloat = direction == .right ? 0 : 180
            NSGradient(colors: fillColors)?.draw(in: arrowPath, angle: angle)
        }
    }

    private static func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
    }

    private static func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor, lineWidth: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setStroke()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawGlow(center: CGPoint, radius: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        path.addClip()
        NSGradient(colors: [color, color.withAlphaComponent(0)])?.draw(
            fromCenter: center,
            radius: 0,
            toCenter: center,
            radius: radius,
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func withShadow(color: NSColor, blur: CGFloat, offset: NSSize, drawing: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = offset
        shadow.set()
        drawing()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
