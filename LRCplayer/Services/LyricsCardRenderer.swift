import AVFoundation
import UIKit

/// What a shared lyrics card shows behind the words.
enum LyricsCardBackground: Hashable, Sendable {
    /// The player's own: the cover's colors in four soft blooms.
    case blur
    case palette(CoverPalette)
    case black
    case white

    var isLight: Bool { self == .white }

    static var all: [LyricsCardBackground] {
        [.blur] + CoverPalette.allCases.filter { $0 != .noir && $0 != .graphite }.map { .palette($0) } + [.black, .white]
    }
}

/// One line of the card, with its words' timings on the lyrics' clock.
struct LyricsCardLine: Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// One per word, or nil (the line lights as a whole).
    var words: [WordTiming]?
}

/// Draws a story-sized (9:16) lyrics card: the cover with the title and
/// artist, then the lines in the player's bold lyrics type. At a moment of
/// the song, the lines light like the full screen player's: the sung one
/// word by word with a soft edge (held notes glowing), the others dim.
final class LyricsCardRenderer: @unchecked Sendable {
    /// The card's width in pixels; its height follows what it holds, up to
    /// a story's 9:16.
    static let width: CGFloat = 1080
    static let maxHeight: CGFloat = 1920

    private(set) var size: CGSize = .zero
    private let scale: CGFloat
    private let lines: [LyricsCardLine]
    private let isLight: Bool
    private var background: CGImage?
    private let header: CGImage?
    private let headerRect: CGRect
    private var laidOut: [LaidOutLine] = []

    private struct LaidOutLine {
        let image: CGImage
        let rect: CGRect
        /// Each word's piece (per wrapped row), in the line's own points.
        let pieces: [(rect: CGRect, timing: WordTiming)]
        let line: LyricsCardLine
    }

    /// `width`: the output's in pixels (the card's, or a preview's).
    init(width: CGFloat, lines: [LyricsCardLine], title: String, artist: String, cover: UIImage?, coverColors: [UIColor], background: LyricsCardBackground) {
        self.scale = width / Self.width
        self.lines = lines
        self.isLight = background.isLight
        let size = CGSize(width: width, height: 0)

        // The header: cover, then title and artist beside it.
        let s = scale
        let margin = 96 * s
        let coverSide = 168 * s
        let titleFont = UIFont.systemFont(ofSize: 44 * s, weight: .bold)
        let artistFont = UIFont.systemFont(ofSize: 38 * s, weight: .semibold)
        let textWidth = size.width - margin * 2 - coverSide - 32 * s
        let headerSize = CGSize(width: size.width - margin * 2, height: coverSide)
        let isLight = background.isLight
        let color = isLight ? UIColor.black : UIColor.white
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        self.header = UIGraphicsImageRenderer(size: headerSize, format: format).image { context in
            let rect = CGRect(x: 0, y: 0, width: coverSide, height: coverSide)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 22 * s)
            context.cgContext.saveGState()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 8 * s), blur: 30 * s, color: UIColor.black.withAlphaComponent(isLight ? 0.18 : 0.35).cgColor)
            UIColor.darkGray.setFill()
            path.fill()
            context.cgContext.restoreGState()
            path.addClip()
            if let cover {
                cover.draw(in: rect)
            }
            context.cgContext.resetClip()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleText = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: color, .paragraphStyle: paragraph])
            let artistText = NSAttributedString(string: artist, attributes: [.font: artistFont, .foregroundColor: color.withAlphaComponent(0.62), .paragraphStyle: paragraph])
            let titleHeight = ceil(titleFont.lineHeight)
            let artistHeight = ceil(artistFont.lineHeight)
            let top = (coverSide - titleHeight - artistHeight - 4 * s) / 2
            let x = coverSide + 32 * s
            titleText.draw(with: CGRect(x: x, y: top, width: textWidth, height: titleHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            artistText.draw(with: CGRect(x: x, y: top + titleHeight + 4 * s, width: textWidth, height: artistHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }.cgImage
        self.headerRect = CGRect(origin: .zero, size: headerSize)
        layOut(width: width, margin: margin)
        self.background = Self.drawBackground(background, colors: coverColors, size: self.size)
    }

    // MARK: Layout

    private func layOut(width cardWidth: CGFloat, margin: CGFloat) {
        let s = scale
        let width = cardWidth - margin * 2
        let gap = 34 * s
        let headerGap = 84 * s
        let verticalMargin = 140 * s
        let available = Self.maxHeight * s - verticalMargin * 2 - headerRect.height - headerGap
        // The player's bold, as big as fits a story.
        var fontSize: CGFloat = 76 * s
        var layouts: [(NSTextStorage, NSLayoutManager, NSTextContainer, CGSize)] = []
        while true {
            layouts = lines.map { Self.layout($0.text, font: UIFont.systemFont(ofSize: fontSize, weight: .bold), width: width) }
            let height = layouts.reduce(0) { $0 + $1.3.height } + gap * CGFloat(max(lines.count - 1, 0))
            if height <= available || fontSize <= 34 * s { break }
            fontSize -= 4 * s
        }
        let linesHeight = layouts.reduce(0) { $0 + $1.3.height } + gap * CGFloat(max(lines.count - 1, 0))
        let total = headerRect.height + headerGap + linesHeight
        // As tall as the content (never flatter than 2:1), in steps of 16
        // pixels on the full card, as video encoders want.
        let canvasHeight = min(max((total + verticalMargin * 2) / s, Self.width / 2), Self.maxHeight)
        size = CGSize(width: cardWidth, height: (canvasHeight / 16).rounded(.up) * 16 * s)
        var y = max(verticalMargin * 0.6, (size.height - total) / 2)
        var header = headerRect
        header.origin = CGPoint(x: margin, y: y)
        headerFrame = header
        y += headerRect.height + headerGap

        let padding: CGFloat = 24 * s
        laidOut = []
        for (line, layout) in zip(lines, layouts) {
            let (storage, manager, container, used) = layout
            let imageSize = CGSize(width: width + padding * 2, height: used.height + padding * 2)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let glyphs = manager.glyphRange(for: container)
            storage.addAttribute(.foregroundColor, value: isLight ? UIColor.black : UIColor.white, range: NSRange(location: 0, length: storage.length))
            let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
                manager.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: padding, y: padding))
            }
            var pieces: [(CGRect, WordTiming)] = []
            let text = line.text
            let ranges = LyricWords.ranges(in: text)
            let timings = line.words ?? []
            for (index, range) in ranges.enumerated() {
                let timing = timings.indices.contains(index) ? timings[index] : WordTiming(start: line.start, end: line.start)
                let glyphRange = manager.glyphRange(forCharacterRange: NSRange(range, in: text), actualCharacterRange: nil)
                var rects: [CGRect] = []
                manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineRange, _ in
                    let part = NSIntersectionRange(glyphRange, lineRange)
                    guard part.length > 0 else { return }
                    rects.append(manager.boundingRect(forGlyphRange: part, in: container))
                }
                let total = max(rects.reduce(0) { $0 + $1.width }, 1)
                var start = timing.start
                for rect in rects {
                    let end = start + (timing.end - timing.start) * rect.width / total
                    pieces.append((rect.offsetBy(dx: padding, dy: padding).insetBy(dx: -3 * s, dy: -4 * s), WordTiming(start: start, end: end)))
                    start = end
                }
            }
            if let cg = image.cgImage {
                laidOut.append(LaidOutLine(image: cg, rect: CGRect(x: margin - padding, y: y - padding, width: imageSize.width, height: imageSize.height), pieces: pieces, line: line))
            }
            y += used.height + gap
        }
    }

    private var headerFrame: CGRect = .zero

    private static func layout(_ text: String, font: UIFont, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer, CGSize) {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return (storage, manager, container, CGSize(width: width, height: ceil(used.maxY)))
    }

    // MARK: Drawing

    /// The card at `time` (lyrics' clock); nil: every line lit, the still.
    /// `backdrop`: false when the background and header are already there
    /// (the video copies them in, drawn once).
    func draw(at time: TimeInterval?, in context: CGContext, backdrop: Bool = true) {
        // UIKit's top-left origin.
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let full = CGRect(origin: .zero, size: size)
        if backdrop, let background { drawImage(background, in: full, context: context, alpha: 1) }
        if backdrop, let header { drawImage(header, in: headerFrame, context: context, alpha: 1) }

        for laid in laidOut {
            guard let time else {
                drawImage(laid.image, in: laid.rect, context: context, alpha: 1)
                continue
            }
            let line = laid.line
            let dim: CGFloat = time < line.start ? 0.42 : 0.3
            // Eased like the player's cells (0.5 s).
            let isCurrent = time >= line.start && time < line.end
            let fadeOut = Self.ease(min(1, max(0, (time - line.end) / 0.5)))
            if !isCurrent && time >= line.end {
                drawImage(laid.image, in: laid.rect, context: context, alpha: 1 - (1 - 0.3) * fadeOut)
                continue
            }
            guard isCurrent else {
                drawImage(laid.image, in: laid.rect, context: context, alpha: dim)
                continue
            }
            guard line.words != nil else {
                let fadeIn = Self.ease(min(1, (time - line.start) / 0.5))
                drawImage(laid.image, in: laid.rect, context: context, alpha: 0.42 + 0.58 * fadeIn)
                continue
            }
            // Unsung words dim, the sung part lit with a soft edge.
            drawImage(laid.image, in: laid.rect, context: context, alpha: 0.42)
            // Words fully sung (and done glowing) are solid: lit together in
            // one draw (their soft edge is gone, so it's the same picture).
            var done: [CGRect] = []
            for piece in laid.pieces {
                let progress = Self.progress(time, piece.timing)
                guard progress > 0 else { continue }
                let rect = piece.rect.offsetBy(dx: laid.rect.minX, dy: laid.rect.minY)
                // Held notes glow, fading out after they end.
                let held = piece.timing.end - piece.timing.start
                let after = max(0, time - piece.timing.end)
                let glow = held >= 0.7 ? min(1, (held - 0.4) / 0.8) * max(0, 1 - after / 0.6) : 0
                if progress >= 1, glow <= 0.01 {
                    done.append(rect)
                } else {
                    drawSung(laid, word: rect, progress: progress, glow: glow, context: context)
                }
            }
            if !done.isEmpty {
                context.saveGState()
                context.clip(to: done)
                drawImage(laid.image, in: laid.rect, context: context, alpha: 1)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    private func drawSung(_ laid: LaidOutLine, word: CGRect, progress: CGFloat, glow: CGFloat, context: CGContext) {
        let edge = min(word.width * 0.6, 22 * scale)
        let lit = word.width * progress
        context.saveGState()
        if glow > 0.01 {
            context.setShadow(offset: .zero, blur: 18 * scale * glow, color: (isLight ? UIColor.black : UIColor.white).withAlphaComponent(0.55 * glow).cgColor)
        }
        // Solid up to the edge, then a few steps fading out.
        let solid = max(0, lit - edge)
        if solid > 0 {
            context.saveGState()
            context.clip(to: CGRect(x: word.minX, y: word.minY, width: solid, height: word.height))
            drawImage(laid.image, in: laid.rect, context: context, alpha: 1)
            context.restoreGState()
        }
        // The soft edge, gone by the word's end.
        let steps = 8
        let edgeStart = word.minX + solid
        let edgeWidth = min(edge, lit)
        let softness = min(1, (1 - progress) * 4)
        for step in 0..<steps where edgeWidth > 0 {
            let x = edgeStart + edgeWidth * CGFloat(step) / CGFloat(steps)
            let alpha = 1 - softness * (CGFloat(step) + 0.5) / CGFloat(steps)
            context.saveGState()
            context.clip(to: CGRect(x: x, y: word.minY, width: edgeWidth / CGFloat(steps) + 0.5, height: word.height))
            // Over the dim copy already drawn: reach 1 at full.
            drawImage(laid.image, in: laid.rect, context: context, alpha: max(0, (alpha - 0.42) / 0.58))
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext, alpha: CGFloat) {
        // Images draw upside down in the flipped context: flip them back.
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func progress(_ time: TimeInterval, _ timing: WordTiming) -> CGFloat {
        guard time > timing.start else { return 0 }
        let length = max(timing.end - timing.start, 0.08)
        return CGFloat(min(1, (time - timing.start) / length))
    }

    private static func ease(_ x: Double) -> CGFloat {
        CGFloat(x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2)
    }

    /// Only the background and header (the lines go over them).
    func drawBackdrop(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        if let background { drawImage(background, in: CGRect(origin: .zero, size: size), context: context, alpha: 1) }
        if let header { drawImage(header, in: headerFrame, context: context, alpha: 1) }
        context.restoreGState()
    }

    /// What a frame shows, finely enough that equal keys draw the same
    /// picture: a still moment repeats the frame before instead of drawing it.
    func frameKey(at time: TimeInterval) -> [Int] {
        lineKeys(at: time).flatMap { $0 }
    }

    /// Each line's spot on the card (top-left points), for redrawing only
    /// the lines that change.
    var lineRects: [CGRect] { laidOut.map(\.rect) }

    /// Per line, what it shows at `time`: a line whose key is unchanged
    /// needn't be drawn again.
    func lineKeys(at time: TimeInterval) -> [[Int]] {
        laidOut.map { laid in
            var key: [Int] = []
            let line = laid.line
            if time < line.start { return [-1] }
            if time >= line.end {
                return [1000 + Int(Self.ease(min(1, max(0, (time - line.end) / 0.5))) * 255)]
            }
            guard line.words != nil else {
                return [2000 + Int(Self.ease(min(1, (time - line.start) / 0.5)) * 255)]
            }
            key.append(3000)
            for piece in laid.pieces {
                let progress = Self.progress(time, piece.timing)
                let held = piece.timing.end - piece.timing.start
                let after = max(0, time - piece.timing.end)
                let glow = held >= 0.7 ? min(1, (held - 0.4) / 0.8) * max(0, 1 - after / 0.6) : 0
                key.append(Int(progress * 2000))
                key.append(Int(glow * 255))
            }
            return key
        }
    }

    func image(at time: TimeInterval?) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            // The renderer's context is already top-left: undo our flip.
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            draw(at: time, in: context.cgContext)
        }
    }

    // MARK: Backgrounds

    private static func drawBackground(_ background: LyricsCardBackground, colors: [UIColor], size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let rect = CGRect(origin: .zero, size: size)
            let space = CGColorSpaceCreateDeviceRGB()
            switch background {
            case .black:
                UIColor.black.setFill()
                cg.fill(rect)
            case .white:
                UIColor.white.setFill()
                cg.fill(rect)
            case .palette(let palette):
                let c = palette.colors
                let start = UIColor(red: c.start.red / 255, green: c.start.green / 255, blue: c.start.blue / 255, alpha: 1)
                let end = UIColor(red: c.end.red / 255, green: c.end.green / 255, blue: c.end.blue / 255, alpha: 1)
                let glow = UIColor(red: c.glow.red / 255, green: c.glow.green / 255, blue: c.glow.blue / 255, alpha: 1)
                if let gradient = CGGradient(colorsSpace: space, colors: [start.cgColor, end.cgColor] as CFArray, locations: [0, 1]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
                if let gradient = CGGradient(colorsSpace: space, colors: [glow.withAlphaComponent(0.55).cgColor, glow.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
                    cg.drawRadialGradient(gradient, startCenter: CGPoint(x: size.width * 0.2, y: size.height * 0.15), startRadius: 0, endCenter: CGPoint(x: size.width * 0.2, y: size.height * 0.15), endRadius: size.height * 0.55, options: [])
                }
                // A little darker at the bottom, like the covers.
                if let shade = CGGradient(colorsSpace: space, colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.28).cgColor] as CFArray, locations: [0, 1]) {
                    cg.drawLinearGradient(shade, start: CGPoint(x: 0, y: size.height * 0.4), end: CGPoint(x: 0, y: size.height), options: [])
                }
            case .blur:
                // The player's: dark base, four blooms near the corners,
                // a scrim and a vignette.
                UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1).setFill()
                cg.fill(rect)
                let diameter = max(size.width, size.height) * 1.1
                let centers = [
                    CGPoint(x: size.width * 0.12, y: size.height * 0.14),
                    CGPoint(x: size.width * 0.88, y: size.height * 0.14),
                    CGPoint(x: size.width * 0.12, y: size.height * 0.82),
                    CGPoint(x: size.width * 0.88, y: size.height * 0.82)
                ]
                let palette = colors.isEmpty ? Song.fallbackArtworkUIColors : colors
                for (index, center) in centers.enumerated() {
                    let color = palette[index % palette.count]
                    let stops: [CGFloat] = [0.92, 0.68, 0.35, 0.12, 0]
                    if let gradient = CGGradient(colorsSpace: space, colors: stops.map { color.withAlphaComponent($0).cgColor } as CFArray, locations: [0, 0.25, 0.55, 0.8, 1]) {
                        cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: diameter / 2, options: [])
                    }
                }
                UIColor.black.withAlphaComponent(0.2).setFill()
                cg.fill(rect)
                if let vignette = CGGradient(colorsSpace: space, colors: [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.12).cgColor, UIColor.black.withAlphaComponent(0.38).cgColor] as CFArray, locations: [0, 0.5, 1]) {
                    cg.drawLinearGradient(vignette, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
            }
        }.cgImage
    }
}

// MARK: - Export

enum LyricsCardExporter {
    enum ExportError: LocalizedError {
        case audio, video
        var errorDescription: String? {
            switch self {
            case .audio: String(localized: "This song's audio can't be read (protected or in the cloud).")
            case .video: String(localized: "The video couldn't be made.")
            }
        }
    }

    static func writeImage(_ image: UIImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lyrics-\(UUID().uuidString.prefix(6)).png")
        guard let data = image.pngData() else { throw ExportError.video }
        try data.write(to: url)
        return url
    }

    /// A video of the card from `start` to `end` (lyrics' clock), the lines
    /// lighting as they're sung, over the song's audio from that moment.
    /// One pass: the frames and the audio go straight into the final file.
    static func writeVideo(renderer: LyricsCardRenderer, start: TimeInterval, end: TimeInterval, audioURL: URL?, audioOffset: TimeInterval, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let size = renderer.size
        let fps: Int32 = 30
        let duration = end - start
        let frames = Int(duration * Double(fps))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Lyrics-\(UUID().uuidString.prefix(6)).mp4")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // HEVC: the same picture in about half the size of H.264 (the card
            // is mostly still, which it packs very well).
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 4
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(input)

        // The song's audio from that moment, faded in and out, encoded as it's read.
        let audio = try await audioSource(url: audioURL, start: max(0, start - audioOffset), duration: duration)
        var audioInput: AVAssetWriterInput?
        if audio != nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audioWriterInput.expectsMediaDataInRealTime = false
            writer.add(audioWriterInput)
            audioInput = audioWriterInput
        }
        guard writer.startWriting() else { throw ExportError.video }
        writer.startSession(atSourceTime: .zero)
        if let audio, !audio.reader.startReading() { throw ExportError.audio }

        var pendingAudio: CMSampleBuffer?
        var audioDone = audio == nil
        /// Audio up to `time` (a little ahead), so both tracks move together.
        func feedAudio(upTo time: Double) {
            guard let audio, let audioInput else { return }
            while !audioDone, audioInput.isReadyForMoreMediaData {
                if pendingAudio == nil { pendingAudio = audio.output.copyNextSampleBuffer() }
                guard let buffer = pendingAudio else {
                    audioDone = true
                    audioInput.markAsFinished()
                    return
                }
                guard CMSampleBufferGetPresentationTimeStamp(buffer).seconds <= time else { return }
                audioInput.append(buffer)
                pendingAudio = nil
            }
        }

        // The background and header drawn once; each frame starts as a copy.
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.video }
        func makeBuffer() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ExportError.video }
            return buffer
        }
        func context(for buffer: CVPixelBuffer) -> CGContext? {
            CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
        let backdrop = try makeBuffer()
        CVPixelBufferLockBaseAddress(backdrop, [])
        if let context = context(for: backdrop) { renderer.drawBackdrop(in: context) }
        let backdropBytes = CVPixelBufferGetBytesPerRow(backdrop) * CVPixelBufferGetHeight(backdrop)
        defer { CVPixelBufferUnlockBaseAddress(backdrop, []) }

        let rects = renderer.lineRects
        let bytesPerRow = CVPixelBufferGetBytesPerRow(backdrop)
        let height = CVPixelBufferGetHeight(backdrop)
        let width = CVPixelBufferGetWidth(backdrop)
        /// The area in pixels (rows top first), whole and on the canvas.
        func pixelRect(_ rect: CGRect) -> CGRect {
            rect.insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        }
        /// Back to the bare backdrop inside `rect`.
        func restore(_ rect: CGRect, in base: UnsafeMutableRawPointer, from source: UnsafeRawPointer) {
            let x = Int(rect.minX) * 4, length = Int(rect.width) * 4
            for row in Int(rect.minY)..<Int(rect.maxY) {
                memcpy(base + row * bytesPerRow + x, source + row * bytesPerRow + x, length)
            }
        }

        var previous: (keys: [[Int]], buffer: CVPixelBuffer)?
        for frame in 0..<frames {
            let time = Double(frame) / Double(fps)
            while !input.isReadyForMoreMediaData {
                feedAudio(upTo: time + 1)
                try await Task.sleep(for: .milliseconds(2))
            }
            try Task.checkCancellation()
            let at = start + time
            let keys = renderer.lineKeys(at: at)
            let buffer: CVPixelBuffer
            if let previous, previous.keys == keys {
                // Nothing moved: the same picture again.
                buffer = previous.buffer
            } else {
                buffer = try makeBuffer()
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer), let source = CVPixelBufferGetBaseAddress(backdrop),
                   CVPixelBufferGetBytesPerRow(buffer) == bytesPerRow, CVPixelBufferGetHeight(buffer) == height {
                    if let previous {
                        // Only the lines that changed are drawn again: the
                        // frame before, their area back to the backdrop, and
                        // every line drawn there (neighbours overlap a little).
                        CVPixelBufferLockBaseAddress(previous.buffer, .readOnly)
                        if let last = CVPixelBufferGetBaseAddress(previous.buffer) { memcpy(base, last, backdropBytes) }
                        CVPixelBufferUnlockBaseAddress(previous.buffer, .readOnly)
                        let dirty = rects.indices.filter { previous.keys[$0] != keys[$0] }.map { pixelRect(rects[$0]) }
                        for rect in dirty { restore(rect, in: base, from: source) }
                        if let context = context(for: buffer) {
                            // The context is bottom-up: flip the areas to clip.
                            context.clip(to: dirty.map { CGRect(x: $0.minX, y: CGFloat(height) - $0.maxY, width: $0.width, height: $0.height) })
                            renderer.draw(at: at, in: context, backdrop: false)
                        }
                    } else {
                        memcpy(base, source, backdropBytes)
                        if let context = context(for: buffer) { renderer.draw(at: at, in: context, backdrop: false) }
                    }
                } else if let context = context(for: buffer) {
                    renderer.draw(at: at, in: context)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                previous = (keys, buffer)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
            feedAudio(upTo: time + 0.5)
            if frame % 10 == 0 { progress(Double(frame) / Double(max(frames, 1)) * 0.97) }
        }
        input.markAsFinished()
        while !audioDone {
            feedAudio(upTo: .infinity)
            if !audioDone { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw ExportError.video
        }
        progress(1)
        return output
    }

    /// A reader of the song's audio over the clip, faded in and out.
    private static func audioSource(url: URL?, start: TimeInterval, duration: TimeInterval) async throws -> (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput)? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.audio }
        let audioStart = CMTime(seconds: start, preferredTimescale: 600)
        let clip = CMTime(seconds: duration, preferredTimescale: 600)
        let available = (try? await asset.load(.duration)).map { $0 - audioStart } ?? clip
        let length = CMTimeMinimum(clip, available)
        guard length.seconds > 0.5 else { throw ExportError.audio }
        do {
            try track.insertTimeRange(CMTimeRange(start: audioStart, duration: length), of: audioTrack, at: .zero)
        } catch {
            throw ExportError.audio
        }
        // A short fade in and out, not a cut.
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let fade = CMTime(seconds: min(0.6, duration / 4), preferredTimescale: 600)
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: fade))
        parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: length - fade, duration: fade))
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        guard let reader = try? AVAssetReader(asset: composition) else { throw ExportError.audio }
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw ExportError.audio }
        reader.add(output)
        return (reader, output)
    }

}
