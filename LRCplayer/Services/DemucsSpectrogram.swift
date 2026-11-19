import Accelerate

/// HTDemucs' spectrogram and its inverse, done here rather than in the
/// model (Core ML has no complex numbers): torch.stft with n_fft 4096,
/// hop 1024, a periodic Hann window and `normalized`, on a signal padded so
/// frames line up with the hop. One instance per thread (it keeps scratch
/// buffers).
final class DemucsSpectrogram {
    static let nfft = 4096
    static let hop = 1024
    /// The model's fixed input length: 7.8 s at 44.1 kHz.
    static let segment = 343_980
    /// ceil(segment / hop).
    static let frames = 336
    /// The last bin (Nyquist) is dropped.
    static let bins = 2048
    static var spectrumCount: Int { 4 * bins * frames }

    private static let pad = hop / 2 * 3
    /// Frames of the centered STFT: two extra on each side.
    private static let allFrames = frames + 4
    private static let paddedLength = (allFrames - 1) * hop + nfft

    private let window: [Float]
    private let forward: OpaquePointer
    private let inverse: OpaquePointer
    /// Overlap-added squared window, inverted (0 where it vanishes).
    private let envelope: [Float]
    // Scratch buffers.
    private let padded = UnsafeMutablePointer<Float>.allocate(capacity: paddedLength)
    private let frame = UnsafeMutablePointer<Float>.allocate(capacity: nfft)
    private let inRe = UnsafeMutablePointer<Float>.allocate(capacity: nfft / 2)
    private let inIm = UnsafeMutablePointer<Float>.allocate(capacity: nfft / 2)
    private let outRe = UnsafeMutablePointer<Float>.allocate(capacity: nfft / 2)
    private let outIm = UnsafeMutablePointer<Float>.allocate(capacity: nfft / 2)
    private let overlap = UnsafeMutablePointer<Float>.allocate(capacity: paddedLength)

    init() {
        let n = Self.nfft
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(n)) }
        forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        var sum = [Float](repeating: 0, count: Self.paddedLength)
        for t in 0..<Self.allFrames {
            for i in 0..<n { sum[t * Self.hop + i] += window[i] * window[i] }
        }
        envelope = sum.map { $0 > 1e-11 ? 1 / $0 : 0 }
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
        for buffer in [padded, frame, inRe, inIm, outRe, outIm, overlap] { buffer.deallocate() }
    }

    /// Two channels of `segment` samples → [4, bins, frames]: real and
    /// imaginary parts of the left channel, then of the right.
    func spectrogram(left: UnsafePointer<Float>, right: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        for (c, channel) in [left, right].enumerated() {
            fillPadded(channel)
            let re = out + (2 * c) * Self.bins * Self.frames
            let im = out + (2 * c + 1) * Self.bins * Self.frames
            // HTDemucs keeps the frames 2 ..< 2 + frames of the centered STFT.
            for f in 0..<Self.frames {
                let start = (f + 2) * Self.hop
                vDSP_vmul(padded + start, 1, window, 1, frame, 1, vDSP_Length(Self.nfft))
                forwardTransform()
                // zrop doubles the spectrum; `normalized` divides by sqrt(n_fft).
                let scale: Float = 0.5 / 64
                re[f] = outRe[0] * scale
                im[f] = 0
                for k in 1..<Self.bins {
                    re[k * Self.frames + f] = outRe[k] * scale
                    im[k * Self.frames + f] = outIm[k] * scale
                }
            }
        }
    }

    /// [4, bins, frames] → two channels of `segment` samples.
    func waveform(from spectrum: UnsafePointer<Float>, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let n = Self.nfft
        for (c, channel) in [left, right].enumerated() {
            let re = spectrum + (2 * c) * Self.bins * Self.frames
            let im = spectrum + (2 * c + 1) * Self.bins * Self.frames
            vDSP_vclr(overlap, 1, vDSP_Length(Self.paddedLength))
            for f in 0..<Self.frames {
                inRe[0] = re[f]
                inIm[0] = 0 // the dropped Nyquist bin
                for k in 1..<Self.bins {
                    inRe[k] = re[k * Self.frames + f]
                    inIm[k] = im[k * Self.frames + f]
                }
                inverseTransform()
                // zrop's inverse of the undoubled spectrum gives n / 2 × the
                // frame... over n, times sqrt(n_fft) for `normalized`: 1 / 64.
                var scale: Float = 1.0 / 64
                vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(n))
                vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(n))
                let start = (f + 2) * Self.hop
                vDSP_vadd(overlap + start, 1, frame, 1, overlap + start, 1, vDSP_Length(n))
            }
            // Drop the centering (n_fft / 2) and HTDemucs' own padding.
            let offset = n / 2 + Self.pad
            envelope.withUnsafeBufferPointer { e in
                vDSP_vmul(overlap + offset, 1, e.baseAddress! + offset, 1, channel, 1, vDSP_Length(Self.segment))
            }
        }
    }

    /// Reflect-pads the segment twice, as HTDemucs then torch.stft do.
    private func fillPadded(_ x: UnsafePointer<Float>) {
        let length = Self.segment
        let right = Self.pad + Self.frames * Self.hop - length
        let inner = length + Self.pad + right
        let center = Self.nfft / 2
        func first(_ j: Int) -> Float {
            // Index in the first padding (reflect, edge not repeated).
            if j < Self.pad { return x[Self.pad - j] }
            let i = j - Self.pad
            if i < length { return x[i] }
            return x[length - 2 - (i - length)]
        }
        for j in 0..<Self.paddedLength {
            var i = j - center
            if i < 0 { i = -i } else if i >= inner { i = inner - 2 - (i - inner) }
            padded[j] = first(i)
        }
    }

    private func forwardTransform() {
        frame.withMemoryRebound(to: DSPComplex.self, capacity: Self.nfft / 2) { complex in
            var split = DSPSplitComplex(realp: inRe, imagp: inIm)
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.nfft / 2))
        }
        vDSP_DFT_Execute(forward, inRe, inIm, outRe, outIm)
    }

    private func inverseTransform() {
        vDSP_DFT_Execute(inverse, inRe, inIm, outRe, outIm)
        var split = DSPSplitComplex(realp: outRe, imagp: outIm)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: Self.nfft / 2) { complex in
            vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(Self.nfft / 2))
        }
    }
}
