import AppKit
import SwiftUI

enum OrbitSpacing {
    static let compact: CGFloat = 8
    static let tight: CGFloat = 12
    static let regular: CGFloat = 16
    static let section: CGFloat = 24
    static let page: CGFloat = 32
}

enum OrbitRadius {
    static let row: CGFloat = 10
    static let panel: CGFloat = 14
    static let hero: CGFloat = 20
}

enum OrbitPalette {
    static let background = Color(red: 0.972, green: 0.976, blue: 0.986)
    static let sidebar = Color(red: 0.938, green: 0.946, blue: 0.962)
    static let workspace = Color.white.opacity(0.88)
    static let panel = Color.white.opacity(0.92)
    static let panelMuted = Color(red: 0.958, green: 0.966, blue: 0.982)
    static let divider = Color.black.opacity(0.07)
    static let accent = Color(red: 0.15, green: 0.41, blue: 0.9)
    static let accentSoft = accent.opacity(0.1)
    static let accentStrong = accent.opacity(0.18)
    static let successSoft = Color.green.opacity(0.12)
    static let warningSoft = Color.yellow.opacity(0.15)
    static let dangerSoft = Color.red.opacity(0.12)
}

enum OrbitSurfaceTone {
    case neutral
    case accent
    case success
    case warning
    case danger
}

private struct OrbitSurfaceModifier: ViewModifier {
    let tone: OrbitSurfaceTone
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fillStyle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
    }

    private var fillStyle: AnyShapeStyle {
        switch tone {
        case .neutral:
            return AnyShapeStyle(OrbitPalette.panel)
        case .accent:
            return AnyShapeStyle(OrbitPalette.accentSoft)
        case .success:
            return AnyShapeStyle(OrbitPalette.successSoft)
        case .warning:
            return AnyShapeStyle(OrbitPalette.warningSoft)
        case .danger:
            return AnyShapeStyle(OrbitPalette.dangerSoft)
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .neutral:
            return OrbitPalette.divider
        case .accent:
            return OrbitPalette.accent.opacity(0.18)
        case .success:
            return Color.green.opacity(0.2)
        case .warning:
            return Color.yellow.opacity(0.22)
        case .danger:
            return Color.red.opacity(0.2)
        }
    }
}

extension View {
    func orbitSurface(_ tone: OrbitSurfaceTone = .neutral, radius: CGFloat = OrbitRadius.panel) -> some View {
        modifier(OrbitSurfaceModifier(tone: tone, radius: radius))
    }
}
