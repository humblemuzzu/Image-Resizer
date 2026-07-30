// Pure arithmetic for Claude's vision pipeline. No Cocoa, no I/O, no imports —
// every rule here is transcribed from docs/claude-vision-spec.md and is pinned
// by `--selftest` against the numbers published in that spec.
//
// Both entry points (the menu bar app and the standalone script) call into this
// file. They used to each carry their own copy of the limits, which is how the
// script drifted into reading points instead of pixels without anyone noticing.

/// The two resolution tiers Claude runs images through (spec §2).
enum ResolutionTier: String, CaseIterable {
    case standard
    case highResolution

    var limits: VisionLimits {
        switch self {
        case .standard: .standard
        case .highResolution: .highResolution
        }
    }

    var displayName: String {
        switch self {
        case .standard: "Standard (all other models)"
        case .highResolution: "High resolution (Claude 4.7+)"
        }
    }
}

/// The pair of limits Claude satisfies simultaneously when it resizes an image
/// (spec §4). Both must hold; for nearly every screenshot the token limit binds
/// first and the edge limit never comes into play.
struct VisionLimits: Equatable {
    /// Maximum length of either *padded* edge, in pixels.
    let maxEdge: Int
    /// Maximum visual token cost, i.e. number of 28×28 patches.
    let maxTokens: Int

    /// Spec §2: all models other than Claude 4.7 and later.
    static let standard = VisionLimits(maxEdge: 1568, maxTokens: 1568)
    /// Spec §2: Claude 4.7 and later, automatic, no beta header.
    static let highResolution = VisionLimits(maxEdge: 2576, maxTokens: 4784)
}

enum ImageBudget {
    /// Spec §1: Claude views images as 28×28-pixel patches rather than pixels,
    /// so every limit in this file is ultimately a statement about patches.
    static let patchSize = 28

    /// Spec §7. The limit is 10 MB base64 on the Claude API direct and on
    /// claude.ai, but 5 MB on Amazon Bedrock and Google Cloud. We hold the
    /// Bedrock/Vertex figure because a payload that fits it is accepted on every
    /// platform, and the cost of being conservative here is a few hundred KB.
    static let maxBase64Bytes = 5_000_000

    /// Spec §1: `⌈w/28⌉ × ⌈h/28⌉`.
    static func countImageTokens(width: Int, height: Int) -> Int {
        patches(across: width) * patches(across: height)
    }

    /// Spec §5: Claude pads every image, resized or not, out to the next patch
    /// boundary on the bottom and right edges.
    static func paddedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (patches(across: width) * patchSize, patches(across: height) * patchSize)
    }

    /// Spec §7: base64 encodes 3 bytes as 4 characters. The API's size limit is
    /// on this number, so comparing raw bytes against it passes payloads that
    /// are then rejected — a 4.5 MB PNG is a 6 MB request body.
    static func base64Bytes(_ rawBytes: Int) -> Int {
        ((rawBytes + 2) / 3) * 4
    }

    /// Spec §4: an image fits when neither *padded* edge exceeds the edge limit
    /// and its token cost is within budget. Testing the padded edge rather than
    /// the raw edge is load-bearing — it is what the live API does.
    static func fits(width: Int, height: Int, limits: VisionLimits) -> Bool {
        let padded = paddedSize(width: width, height: height)
        return padded.width <= limits.maxEdge
            && padded.height <= limits.maxEdge
            && countImageTokens(width: width, height: height) <= limits.maxTokens
    }

    /// The size Claude resizes an image to before padding (spec §4/§6).
    ///
    /// An image can be entirely inside the edge limit and still be resized: an
    /// A4 page at 130 DPI is 1075×1520, under 1568 on both sides, but costs
    /// 39×55 = 2145 tokens and comes back as 924×1307. Enforcing only the long
    /// edge — which this app used to do — misses that entirely.
    static func resizedSize(width: Int, height: Int, limits: VisionLimits = .standard) -> (width: Int, height: Int) {
        if fits(width: width, height: height, limits: limits) {
            return (width, height)
        }

        // The search below only ever shrinks the *first* argument, so a portrait
        // image is solved by swapping the axes and swapping the answer back.
        if height > width {
            let flipped = resizedSize(width: height, height: width, limits: limits)
            return (flipped.height, flipped.width)
        }

        // Binary search the long edge for the largest aspect-preserving size that
        // fits. `lo` always fits, `hi` never does, and they close to adjacency.
        let aspectRatio = Double(width) / Double(height)
        var lo = 1
        var hi = width
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if fits(width: mid, height: shortEdge(forLongEdge: mid, aspectRatio: aspectRatio), limits: limits) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (lo, shortEdge(forLongEdge: lo, aspectRatio: aspectRatio))
    }

    /// The exact size to produce so that Claude's own pipeline resizes nothing
    /// (spec §4) — one resampling pass instead of two, which is visibly better
    /// for text (spec §9).
    ///
    /// Returns `nil` when the image already fits: resampling an image that needs
    /// no resampling only costs quality.
    ///
    /// `snapToPatchGrid` additionally lands both axes on a multiple of 28 so that
    /// Claude pads nothing (spec §5). It is OFF BY DEFAULT, and that is a
    /// deliberate reversal. Snapping trims each axis independently, so it does not
    /// preserve the aspect ratio: measured across real screenshots it stretches by
    /// up to 2.7% (3024×1964 lands on 1372×868 instead of 1372×891), and a 1920×1080
    /// frame is squashed 0.86% vertically to save 52 of 1560 tokens. Trading
    /// geometry for 3% of the budget is the wrong default for a tool whose whole
    /// job is handing Claude an accurate picture — and coordinates read off a
    /// stretched screenshot are wrong in a way nobody can see. Callers that want
    /// the last few tokens can ask for it.
    static func targetSize(
        width: Int,
        height: Int,
        limits: VisionLimits = .standard,
        snapToPatchGrid: Bool = false
    ) -> (width: Int, height: Int)? {
        let resized = resizedSize(width: width, height: height, limits: limits)
        guard resized.width != width || resized.height != height else { return nil }
        guard snapToPatchGrid else { return resized }
        return snappedToPatchGrid(width: resized.width, height: resized.height)
    }

    /// Scales a target down, staying on the patch grid. Reached only when a PNG
    /// at the ideal size still blows the base64 budget: spec §9 says fewer pixels
    /// beat lossy artefacts, so dimensions come down before quality does.
    /// A factor of 1 is an identity, not a snap: the caller's target is already on
    /// the grid when it came from `targetSize`, and snapping a source whose
    /// dimensions were never the problem would resample it for nothing.
    static func scaledDown(width: Int, height: Int, by factor: Double) -> (width: Int, height: Int) {
        guard factor < 1 else { return (width, height) }
        return snappedToPatchGrid(
            width: max(Int(Double(width) * factor), 1),
            height: max(Int(Double(height) * factor), 1)
        )
    }

    /// Spec §5: an image whose sides are already multiples of 28 is padded by
    /// nothing and wastes no tokens. Snapping *down* trims at most 27 px per axis
    /// and can only lower the token count, so it can never break a limit that the
    /// resize just satisfied. Skipped on an axis under one patch wide, where
    /// flooring would produce zero.
    ///
    /// Trims the axes independently, so THIS DOES NOT PRESERVE ASPECT RATIO —
    /// up to 2.7% of stretch on real inputs. See `targetSize`, which leaves it off
    /// by default for that reason.
    static func snappedToPatchGrid(width: Int, height: Int) -> (width: Int, height: Int) {
        (snappedDown(width), snappedDown(height))
    }

    private static func snappedDown(_ pixels: Int) -> Int {
        let snapped = (pixels / patchSize) * patchSize
        return snapped >= patchSize ? snapped : pixels
    }

    private static func patches(across pixels: Int) -> Int {
        max((pixels + patchSize - 1) / patchSize, 0)
    }

    /// Spec §6: the reference implementation uses Python's `round`, which is
    /// half-to-even, and the live API resolves exact .5 ties toward the even
    /// neighbour too. Swift's bare `rounded()` is half-away-from-zero and gives a
    /// different answer on ties, so `.toNearestOrEven` is mandatory here.
    private static func shortEdge(forLongEdge longEdge: Int, aspectRatio: Double) -> Int {
        max(Int((Double(longEdge) / aspectRatio).rounded(.toNearestOrEven)), 1)
    }
}
