import SwiftUI

struct OpenIslandBrandMark: View {
    enum Style {
        case duotone
        case template
    }

    enum Preset: String {
        case scout
        case orb
        case flare
        case array
        case halo
    }

    let size: CGFloat
    var tint: Color = .mint
    var isAnimating: Bool = false
    var style: Style = .duotone
    var preset: Preset = .scout

    private static let scoutPattern = [
        "..B..B..",
        "..BBBB..",
        ".BHHHHB.",
        "BBHEHEBB",
        ".BHHHHB.",
        "..BBBB..",
        ".B....B.",
        "........",
    ]

    private static let orbPattern = [
        "...BB...",
        "..BHHB..",
        ".BHHHHB.",
        ".BHHEHB.",
        ".BHHHHB.",
        "..BHHB..",
        "...BB...",
        "........",
    ]

    private static let flarePattern = [
        "...B....",
        "..BHB...",
        ".BHHHB..",
        "BBHEHBB.",
        ".BHHHB..",
        "..BHB...",
        "...B....",
        "........",
    ]

    private static let arrayPattern = [
        "B.B..B.B",
        ".HH..HH.",
        "BHEBBEHB",
        ".HH..HH.",
        "B.B..B.B",
        "..B..B..",
        ".B....B.",
        "........",
    ]

    private static let haloPattern = [
        "..BBBB..",
        ".B....B.",
        "B.HHHH.B",
        "B.HHEH.B",
        "B.HHHH.B",
        ".B....B.",
        "..BBBB..",
        "........",
    ]

    var body: some View {
        GeometryReader { proxy in
            let cell = min(proxy.size.width / 8, proxy.size.height / 8)
            let markWidth = cell * 8
            let markHeight = cell * 8
            let originX = (proxy.size.width - markWidth) / 2
            let originY = (proxy.size.height - markHeight) / 2

            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.pixels(for: preset).enumerated()), id: \.offset) { _, pixel in
                    Rectangle()
                        .fill(fillColor(for: pixel.role))
                        .frame(width: cell, height: cell)
                        .offset(
                            x: originX + CGFloat(pixel.x) * cell,
                            y: originY + CGFloat(pixel.y) * cell
                        )
                }
            }
        }
        .frame(width: size, height: size)
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
    }

    private static func pixels(for preset: Preset) -> [(x: Int, y: Int, role: Character)] {
        let pattern: [String]
        switch preset {
        case .scout:
            pattern = scoutPattern
        case .orb:
            pattern = orbPattern
        case .flare:
            pattern = flarePattern
        case .array:
            pattern = arrayPattern
        case .halo:
            pattern = haloPattern
        }

        return pattern.enumerated().flatMap { rowIndex, row in
            row.enumerated().compactMap { columnIndex, character in
                character == "." ? nil : (columnIndex, rowIndex, character)
            }
        }
    }

    private func fillColor(for role: Character) -> Color {
        switch style {
        case .duotone:
            switch role {
            case "B":
                return tint.opacity(isAnimating ? 1.0 : 0.86)
            case "H":
                return tint.opacity(isAnimating ? 0.84 : 0.64)
            case "E":
                return Color.black.opacity(0.72)
            default:
                return .clear
            }
        case .template:
            return Color.primary.opacity(role == "E" ? 0.9 : 1.0)
        }
    }
}
