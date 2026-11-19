import UIKit

// MARK: - Palettes

/// Hand-tuned two-color gradients for the generated covers.
enum CoverPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case ember
    case sunrise
    case lime
    case lagoon
    case indigo
    case orchid
    case midnight
    case graphite
    case peach
    case mint
    case ocean
    case rose
    case forest
    case dusk
    case cherry
    case noir

    var id: Self { self }

    var title: String {
        switch self {
        case .ember: String(localized: "Ember", comment: "Cover color palette")
        case .sunrise: String(localized: "Sunrise", comment: "Cover color palette")
        case .lime: String(localized: "Lime", comment: "Cover color palette")
        case .lagoon: String(localized: "Lagoon", comment: "Cover color palette")
        case .indigo: String(localized: "Indigo", comment: "Cover color palette")
        case .orchid: String(localized: "Orchid", comment: "Cover color palette")
        case .midnight: String(localized: "Midnight", comment: "Cover color palette")
        case .graphite: String(localized: "Graphite", comment: "Cover color palette")
        case .peach: String(localized: "Peach", comment: "Cover color palette")
        case .mint: String(localized: "Mint", comment: "Cover color palette")
        case .ocean: String(localized: "Ocean", comment: "Cover color palette")
        case .rose: String(localized: "Rose", comment: "Cover color palette")
        case .forest: String(localized: "Forest", comment: "Cover color palette")
        case .dusk: String(localized: "Dusk", comment: "Cover color palette")
        case .cherry: String(localized: "Cherry", comment: "Cover color palette")
        case .noir: String(localized: "Noir", comment: "Cover color palette")
        }
    }

    /// Top-left, bottom-right and glow colors, 0–255 RGB.
    var colors: (start: RGB, end: RGB, glow: RGB) {
        switch self {
        case .ember: (RGB(255, 45, 85), RGB(255, 128, 36), RGB(255, 200, 120))
        case .sunrise: (RGB(255, 184, 0), RGB(255, 84, 52), RGB(255, 236, 140))
        case .lime: (RGB(52, 199, 89), RGB(0, 160, 190), RGB(200, 255, 120))
        case .lagoon: (RGB(0, 200, 210), RGB(10, 90, 230), RGB(130, 240, 255))
        case .indigo: (RGB(88, 86, 214), RGB(30, 30, 120), RGB(150, 140, 255))
        case .orchid: (RGB(255, 80, 160), RGB(130, 60, 240), RGB(255, 170, 220))
        case .midnight: (RGB(40, 60, 130), RGB(10, 14, 40), RGB(90, 140, 255))
        case .graphite: (RGB(110, 110, 120), RGB(28, 28, 32), RGB(200, 200, 210))
        case .peach: (RGB(255, 170, 140), RGB(240, 90, 120), RGB(255, 225, 190))
        case .mint: (RGB(120, 230, 190), RGB(20, 140, 140), RGB(210, 255, 230))
        case .ocean: (RGB(40, 120, 200), RGB(6, 30, 80), RGB(120, 220, 255))
        case .rose: (RGB(250, 190, 200), RGB(190, 90, 130), RGB(255, 235, 240))
        case .forest: (RGB(70, 140, 90), RGB(14, 46, 34), RGB(190, 230, 140))
        case .dusk: (RGB(250, 120, 90), RGB(70, 40, 120), RGB(255, 190, 120))
        case .cherry: (RGB(220, 20, 60), RGB(80, 0, 30), RGB(255, 120, 140))
        case .noir: (RGB(70, 70, 76), RGB(6, 6, 8), RGB(255, 255, 255))
        }
    }

    /// The playlist page behind the cover: the gradient's end, darkened like
    /// album pages are.
    var pageColor: RGB {
        let end = colors.end
        return RGB(end.red * 0.42, end.green * 0.42, end.blue * 0.42)
    }

    struct RGB: Sendable {
        let red, green, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }
}

/// How a generated cover is drawn. `classic` is the original design.
enum CoverStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic, aurora, vinyl, waves, poster, sunset

    var id: Self { self }

    var title: String {
        switch self {
        case .classic: String(localized: "Rings")
        case .aurora: String(localized: "Aurora")
        case .vinyl: String(localized: "Vinyl")
        case .waves: String(localized: "Waves")
        case .poster: String(localized: "Poster")
        case .sunset: String(localized: "Sunset")
        }
    }
}

/// Everything drawn on a generated cover (Autolists, playlists); also the
/// cover's cache identity.
struct GeneratedCover: Hashable, Sendable {
    var number: String?
    var title: String
    var caption: String
    var symbol: String
    var palette: CoverPalette
    var style: CoverStyle = .classic

    var cacheKey: String {
        ["autolist", number ?? "", title, caption, symbol, palette.rawValue, style == .classic ? "" : style.rawValue].joined(separator: "|")
    }
}

// MARK: - Renderer


/// Draws generated covers: a diagonal gradient with a soft glow, two rings
/// echoing a record, the selection's symbol, and the description in bold type.
/// Pure Core Graphics, so the artwork cache can render it off the main thread
/// at whatever size is displayed.
enum GeneratedCoverRenderer {
    static func image(for cover: GeneratedCover, pixels: Int) -> UIImage {
        let side = CGFloat(pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            draw(cover, side: side, in: context.cgContext)
        }
    }

    private static func draw(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        switch cover.style {
        case .classic: drawClassic(cover, side: side, in: context)
        case .aurora: drawAurora(cover, side: side, in: context)
        case .vinyl: drawVinyl(cover, side: side, in: context)
        case .waves: drawWaves(cover, side: side, in: context)
        case .poster: drawPoster(cover, side: side, in: context)
        case .sunset: drawSunset(cover, side: side, in: context)
        }
    }

    private static func drawClassic(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        let colors = cover.palette.colors
        let space = CGColorSpaceCreateDeviceRGB()
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)

        // Diagonal gradient.
        if let gradient = CGGradient(colorsSpace: space, colors: [cgColor(colors.start), cgColor(colors.end)] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // Glow in the top-right corner.
        if let glow = CGGradient(colorsSpace: space, colors: [cgColor(colors.glow, alpha: 0.75), cgColor(colors.glow, alpha: 0)] as CFArray, locations: [0, 1]) {
            let center = CGPoint(x: side * 0.86, y: side * 0.08)
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: side * 0.78, options: [])
        }

        // Rings, partly off the edge.
        let ringCenter = CGPoint(x: side * 0.80, y: side * 0.30)
        for (radius, width, alpha) in [(0.25, 0.034, 0.30), (0.39, 0.018, 0.18), (0.53, 0.010, 0.10)] as [(CGFloat, CGFloat, CGFloat)] {
            context.setStrokeColor(UIColor.white.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(side * width)
            context.strokeEllipse(in: CGRect(x: ringCenter.x - side * radius, y: ringCenter.y - side * radius, width: side * radius * 2, height: side * radius * 2))
        }

        drawLabel(cover, side: side, in: context)
    }

    /// The shade, symbol and text block every style but Poster shares.
    private static func drawLabel(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        let space = CGColorSpaceCreateDeviceRGB()
        // Shade under the text so light palettes stay legible.
        if let shade = CGGradient(colorsSpace: space, colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.22).cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(shade, start: CGPoint(x: 0, y: side * 0.4), end: CGPoint(x: 0, y: side), options: [.drawsAfterEndLocation])
        }

        let margin = side * 0.08
        let textWidth = side - margin * 2

        // Symbol, top left, like the mark on Apple Music's own covers.
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: side * 0.09, weight: .semibold)
        if let symbol = UIImage(systemName: cover.symbol, withConfiguration: symbolConfiguration)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            let height = side * 0.1
            let width = height * symbol.size.width / max(symbol.size.height, 1)
            symbol.draw(in: CGRect(x: margin, y: margin, width: width, height: height))
        }

        // Text block, from the bottom up.
        var bottom = side - margin
        if !cover.caption.isEmpty {
            let caption = text(cover.caption, size: side * 0.046, weight: .semibold, alpha: 0.82, lines: 1, width: textWidth)
            bottom -= caption.height
            caption.string.draw(with: CGRect(x: margin, y: bottom, width: textWidth, height: caption.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            bottom -= side * 0.018
        }

        // Without a figure above it, the title gets more room.
        let title = fittedTitle(cover.title, side: side, width: textWidth, large: cover.number == nil)
        bottom -= title.height
        title.string.draw(with: CGRect(x: margin, y: bottom, width: textWidth, height: title.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)

        if let number = cover.number {
            let figure = text(number, size: side * 0.30, weight: .heavy, alpha: 1, lines: 1, width: textWidth, kern: -side * 0.012)
            // The figure's line box carries descender space the digits don't use.
            let descender = UIFont.systemFont(ofSize: side * 0.30, weight: .heavy).descender
            bottom -= figure.height + descender + side * 0.004
            figure.string.draw(with: CGRect(x: margin - side * 0.012, y: bottom, width: textWidth + side * 0.012, height: figure.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }

    // MARK: Styles

    /// Soft blobs of the palette melting into each other on a dark base,
    /// like a mesh gradient.
    private static func drawAurora(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        let colors = cover.palette.colors
        context.setFillColor(cgColor(scaled(colors.end, 0.45)))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let blobs: [(CoverPalette.RGB, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (colors.end, 0.85, 0.75, 0.80, 1),
            (colors.start, 0.18, 0.22, 0.75, 1),
            (colors.glow, 0.78, 0.12, 0.50, 0.85),
            (colors.start, 0.05, 1.0, 0.55, 0.7),
            (colors.glow, 0.45, 0.55, 0.30, 0.35)
        ]
        for (color, x, y, radius, alpha) in blobs {
            radial(color, alpha: alpha, at: CGPoint(x: side * x, y: side * y), radius: side * radius, in: context)
        }
        drawLabel(cover, side: side, in: context)
    }

    /// A record sliding out on the right, its label in the palette's colors.
    private static func drawVinyl(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        let colors = cover.palette.colors
        linear([scaled(colors.start, 0.42), scaled(colors.end, 0.30)], from: .zero, to: CGPoint(x: side, y: side), in: context)
        radial(colors.glow, alpha: 0.35, at: CGPoint(x: side * 0.2, y: side * 0.1), radius: side * 0.7, in: context)

        let center = CGPoint(x: side * 0.80, y: side * 0.40)
        let radius = side * 0.60
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: CGSize(width: -side * 0.02, height: side * 0.02), blur: side * 0.06, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fillEllipse(in: disc)
        context.restoreGState()
        // Grooves.
        var groove = radius * 0.36
        while groove < radius * 0.97 {
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.045).cgColor)
            context.setLineWidth(side * 0.003)
            context.strokeEllipse(in: CGRect(x: center.x - groove, y: center.y - groove, width: groove * 2, height: groove * 2))
            groove += side * 0.016
        }
        // Light sweeping across the vinyl.
        context.saveGState()
        context.addEllipse(in: disc)
        context.clip()
        linear([CoverPalette.RGB(255, 255, 255)], alphas: [0, 0.13, 0], from: CGPoint(x: disc.minX, y: disc.minY), to: CGPoint(x: disc.maxX, y: disc.maxY), in: context)
        context.restoreGState()
        // Label and spindle hole.
        let label = radius * 0.32
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - label, y: center.y - label, width: label * 2, height: label * 2))
        context.clip()
        linear([colors.start, colors.end], from: CGPoint(x: center.x - label, y: center.y - label), to: CGPoint(x: center.x + label, y: center.y + label), in: context)
        context.restoreGState()
        let hole = side * 0.018
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fillEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
        drawLabel(cover, side: side, in: context)
    }

    /// The Waves design on a wide banner, without its label: the year
    /// cards of a playlist's filter row.
    static func wavesBanner(palette: CoverPalette, size: CGSize, scale: CGFloat) -> UIImage {
        wavesBanner(colors: palette.colors, size: size, scale: scale)
    }

    /// The same waves in any colors.
    static func wavesBanner(colors: (start: CoverPalette.RGB, end: CoverPalette.RGB, glow: CoverPalette.RGB), size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let width = size.width, height = size.height
            linear([colors.start, colors.end], from: .zero, to: CGPoint(x: width, y: height), in: context)
            radial(colors.glow, alpha: 0.6, at: CGPoint(x: width * 0.85, y: height * 0.1), radius: width * 0.5, in: context)
            let waves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (0.42, 0.10, 0.55, 0.0, 0.10),
                (0.56, 0.12, 0.42, 1.7, 0.12),
                (0.70, 0.09, 0.65, 3.1, 0.14),
                (0.84, 0.11, 0.48, 4.4, 0.16)
            ]
            for (baseline, amplitude, wavelength, phase, alpha) in waves {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: height))
                for step in 0...64 {
                    let x = width * CGFloat(step) / 64
                    let y = height * baseline + height * amplitude * sin(x / (width * wavelength) * .pi * 2 + phase)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(cgColor(colors.glow, alpha: alpha))
                context.fillPath()
            }
        }
    }

    /// Translucent swells rolling across the palette's gradient.
    private static func drawWaves(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        let colors = cover.palette.colors
        linear([colors.start, colors.end], from: .zero, to: CGPoint(x: side * 0.4, y: side), in: context)
        radial(colors.glow, alpha: 0.6, at: CGPoint(x: side * 0.8, y: side * 0.12), radius: side * 0.6, in: context)
        let waves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            // baseline, amplitude, wavelength, phase, alpha
            (0.36, 0.050, 1.10, 0.0, 0.10),
            (0.46, 0.060, 0.85, 1.7, 0.12),
            (0.56, 0.045, 1.30, 3.1, 0.14),
            (0.66, 0.055, 0.95, 4.4, 0.16)
        ]
        for (baseline, amplitude, wavelength, phase, alpha) in waves {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: side))
            for step in 0...64 {
                let x = side * CGFloat(step) / 64
                let y = side * baseline + side * amplitude * sin(x / (side * wavelength) * .pi * 2 + phase)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: side, y: side))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(cgColor(colors.glow, alpha: alpha))
            context.fillPath()
        }
        drawLabel(cover, side: side, in: context)
    }

    /// Swiss poster: the name huge and tight, a disc of the second color.
    private static func drawPoster(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        let colors = cover.palette.colors
        context.setFillColor(cgColor(colors.start))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let disc = side * 0.62
        context.setFillColor(cgColor(colors.end))
        context.fillEllipse(in: CGRect(x: side * 0.98 - disc, y: side * 1.02 - disc, width: disc * 1.25, height: disc * 1.25))
        context.setFillColor(cgColor(colors.glow, alpha: 0.9))
        let dot = side * 0.11
        context.fillEllipse(in: CGRect(x: side * 0.80, y: side * 0.10, width: dot, height: dot))

        let margin = side * 0.08
        let width = side * 0.80
        var size = side * 0.20
        let words = cover.title.uppercased()
        let longest = words.components(separatedBy: " ").max { $0.count < $1.count } ?? words
        while size > side * 0.07,
              (longest as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .black)]).width > width * 0.82 {
            size -= side * 0.004
        }
        let title = text(words, size: size, weight: .black, alpha: 1, lines: 4, width: width * 0.82, kern: -size * 0.04)
        title.string.draw(with: CGRect(x: margin, y: margin * 1.6, width: width * 0.82, height: title.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)

        // A rule and a small caption at the foot.
        let footY = side - margin - side * 0.04
        context.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        context.fill(CGRect(x: margin, y: footY - side * 0.03, width: side * 0.12, height: max(1, side * 0.006)))
        let foot = text((cover.caption.isEmpty ? String(localized: "Playlist") : cover.caption).uppercased(), size: side * 0.036, weight: .bold, alpha: 0.9, lines: 1, width: width, kern: side * 0.006)
        foot.string.draw(with: CGRect(x: margin, y: footY, width: width, height: foot.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// A striped retro sun rising over the palette.
    private static func drawSunset(_ cover: GeneratedCover, side: CGFloat, in context: CGContext) {
        let colors = cover.palette.colors
        linear([scaled(colors.end, 0.55), colors.end, colors.start], from: .zero, to: CGPoint(x: 0, y: side), in: context)
        let center = CGPoint(x: side * 0.5, y: side * 0.44)
        let radius = side * 0.30
        radial(colors.glow, alpha: 0.55, at: center, radius: radius * 2.1, in: context)
        context.saveGState()
        // Stripes cut out of the lower half, thicker toward the horizon.
        let cut = CGMutablePath()
        cut.addRect(CGRect(x: 0, y: 0, width: side, height: side))
        var y = center.y + radius * 0.12
        var gap = side * 0.008
        while y < center.y + radius {
            cut.addRect(CGRect(x: 0, y: y, width: side, height: gap))
            y += gap + side * 0.03
            gap += side * 0.006
        }
        context.addPath(cut)
        context.clip(using: .evenOdd)
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        linear([colors.glow, colors.start], from: CGPoint(x: 0, y: center.y - radius), to: CGPoint(x: 0, y: center.y + radius), in: context)
        context.restoreGState()
        drawLabel(cover, side: side, in: context)
    }

    // MARK: Drawing helpers

    private static func scaled(_ rgb: CoverPalette.RGB, _ factor: Double) -> CoverPalette.RGB {
        CoverPalette.RGB(rgb.red * factor, rgb.green * factor, rgb.blue * factor)
    }

    private static func radial(_ color: CoverPalette.RGB, alpha: CGFloat, at center: CGPoint, radius: CGFloat, in context: CGContext) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [cgColor(color, alpha: alpha), cgColor(color, alpha: 0)] as CFArray, locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    /// Evenly spread colors; one color with `alphas` fades it instead.
    private static func linear(_ colors: [CoverPalette.RGB], alphas: [CGFloat]? = nil, from start: CGPoint, to end: CGPoint, in context: CGContext) {
        let cgColors: [CGColor] = alphas.map { alphas in alphas.map { cgColor(colors[0], alpha: $0) } } ?? colors.map { cgColor($0) }
        let locations = (0..<cgColors.count).map { CGFloat($0) / CGFloat(max(cgColors.count - 1, 1)) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors as CFArray, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Two lines at most (three without a figure); long words shrink the type
    /// instead of breaking.
    private static func fittedTitle(_ title: String, side: CGFloat, width: CGFloat, large: Bool) -> (string: NSAttributedString, height: CGFloat) {
        var size = side * (large ? 0.13 : 0.112)
        let longestWord = title.components(separatedBy: " ").max { $0.count < $1.count } ?? title
        while size > side * 0.06 {
            let font = UIFont.systemFont(ofSize: size, weight: .bold)
            let wordWidth = (longestWord as NSString).size(withAttributes: [.font: font]).width
            if wordWidth <= width { break }
            size -= side * 0.004
        }
        return text(title, size: size, weight: .bold, alpha: 1, lines: large ? 3 : 2, width: width, kern: -size * 0.01)
    }

    private static func text(_ string: String, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat, lines: Int, width: CGFloat, kern: CGFloat = 0) -> (string: NSAttributedString, height: CGFloat) {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.92
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
            .kern: kern
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let fitted = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil).height
        // Longer text is cut by the drawing rect (`.truncatesLastVisibleLine`).
        let height = min(fitted, font.lineHeight * paragraph.lineHeightMultiple * CGFloat(lines) + 1)
        return (attributed, ceil(height))
    }

    private static func cgColor(_ rgb: CoverPalette.RGB, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: alpha)
    }
}
