// Assertions against the published numbers in docs/claude-vision-spec.md.
// Reached via `--selftest`; exits non-zero on any failure. There is no test
// framework in this project and adding one is out of scope, so this is the
// regression net for the budget maths.

enum ImageBudgetSelfTest {
    static func run() -> Bool {
        var check = Checker()

        // Spec §3 size table, standard tier.
        check.size("resizedSize(1075, 1520)", ImageBudget.resizedSize(width: 1075, height: 1520), (924, 1307))
        check.size("resizedSize(1920, 1080)", ImageBudget.resizedSize(width: 1920, height: 1080), (1456, 819))
        check.size("resizedSize(3840, 2160)", ImageBudget.resizedSize(width: 3840, height: 2160), (1456, 819))
        check.size("resizedSize(1092, 1092)", ImageBudget.resizedSize(width: 1092, height: 1092), (1092, 1092))
        check.size("resizedSize(1000, 1000)", ImageBudget.resizedSize(width: 1000, height: 1000), (1000, 1000))
        check.size("resizedSize(200, 200)", ImageBudget.resizedSize(width: 200, height: 200), (200, 200))

        // Spec §3 size table, high-resolution tier.
        check.size("resizedSize(1075, 1520, highRes)",
                   ImageBudget.resizedSize(width: 1075, height: 1520, limits: .highResolution), (1075, 1520))
        check.size("resizedSize(3840, 2160, highRes)",
                   ImageBudget.resizedSize(width: 3840, height: 2160, limits: .highResolution), (2576, 1449))

        // The one row where spec §3's table and spec §6's reference code disagree.
        // Running Anthropic's Python verbatim returns 1270×952; the table prints
        // 1269×952, which is what half-away-from-zero rounding produces. Spec §6
        // states half-to-even explicitly and says the live API resolves ties the
        // same way, so the code wins. Harmless either way: both sizes cost 1564
        // tokens, so the API resizes neither.
        check.size("resizedSize(2000, 1500) [spec §6 code; §3 table says 1269×952]",
                   ImageBudget.resizedSize(width: 2000, height: 1500), (1270, 952))
        check.isTrue("1269×952 also fits, so the §3/§6 conflict changes nothing operationally",
                     ImageBudget.fits(width: 1269, height: 952, limits: .standard))

        // Portrait input exercises the axis-swap recursion in spec §6.
        check.size("resizedSize(1080, 1920) [axis swap]", ImageBudget.resizedSize(width: 1080, height: 1920), (819, 1456))

        // Pins banker's rounding. Half-away-from-zero yields 963×1232 here, so a
        // refactor to a bare `rounded()` fails this line.
        check.size("resizedSize(1000, 1280) [half-to-even, not half-up]",
                   ImageBudget.resizedSize(width: 1000, height: 1280), (962, 1232))

        // Spec §4's trap: inside the 1568 px edge limit and still resized. This is
        // the case the app used to wave through.
        check.size("resizedSize(1568, 859) [under the edge limit, over the token budget]",
                   ImageBudget.resizedSize(width: 1568, height: 859), (1483, 812))
        check.equal("countImageTokens(1568, 859) exceeds the 1568 budget",
                    ImageBudget.countImageTokens(width: 1568, height: 859), 1736)

        // Spec §1 token counts.
        check.equal("countImageTokens(1000, 1000)", ImageBudget.countImageTokens(width: 1000, height: 1000), 1296)
        check.equal("countImageTokens(1092, 1092)", ImageBudget.countImageTokens(width: 1092, height: 1092), 1521)
        check.equal("countImageTokens(200, 200)", ImageBudget.countImageTokens(width: 200, height: 200), 64)

        // Spec §5 padding.
        check.size("paddedSize(924, 1307)", ImageBudget.paddedSize(width: 924, height: 1307), (924, 1316))

        // Spec §7 base64 expansion.
        check.equal("base64Bytes(4_500_000)", ImageBudget.base64Bytes(4_500_000), 6_000_000)
        check.equal("base64Bytes(0)", ImageBudget.base64Bytes(0), 0)
        check.equal("base64Bytes(1)", ImageBudget.base64Bytes(1), 4)
        check.equal("base64Bytes(3)", ImageBudget.base64Bytes(3), 4)

        // Spec §10 practical ceilings, derived rather than hardcoded.
        check.size("standard square ceiling", ImageBudget.resizedSize(width: 10_000, height: 10_000), (1092, 1092))
        check.size("standard 16:9 ceiling", ImageBudget.resizedSize(width: 3840, height: 2160), (1456, 819))

        // targetSize: what the app actually asks for.
        check.optionalSize("targetSize(1092, 1092) leaves a fitting image alone",
                           ImageBudget.targetSize(width: 1092, height: 1092), nil)
        check.optionalSize("targetSize(200, 200) leaves a fitting image alone",
                           ImageBudget.targetSize(width: 200, height: 200), nil)
        // The DEFAULT preserves aspect ratio exactly — it is Claude's own answer,
        // untouched. Snapping to the patch grid trims the axes independently and
        // therefore stretches, so it is opt-in.
        check.optionalSize("targetSize(1920, 1080) is Claude's exact resize, aspect intact",
                           ImageBudget.targetSize(width: 1920, height: 1080), (1456, 819))
        check.optionalSize("targetSize(1568, 859) fixes the case the old rule passed",
                           ImageBudget.targetSize(width: 1568, height: 859), (1483, 812))
        check.optionalSize("targetSize(1920, 1080, snap: true) trims 819 to the patch grid",
                           ImageBudget.targetSize(width: 1920, height: 1080, snapToPatchGrid: true), (1456, 812))

        // The default must never distort. 819/1456 against 1080/1920 is exact.
        check.isTrue("the default target holds the source aspect ratio to within 0.1%", {
            let t = ImageBudget.targetSize(width: 1920, height: 1080) ?? (1, 1)
            let drift = abs(Double(t.width) / Double(t.height) - 1920.0 / 1080.0) / (1920.0 / 1080.0)
            return drift < 0.001
        }())
        check.isTrue("snapping, when asked for, is what introduces the drift", {
            let t = ImageBudget.targetSize(width: 1920, height: 1080, snapToPatchGrid: true) ?? (1, 1)
            let drift = abs(Double(t.width) / Double(t.height) - 1920.0 / 1080.0) / (1920.0 / 1080.0)
            return drift > 0.008
        }())

        // Spec §5: a patch-aligned image is padded by nothing.
        let aligned = ImageBudget.targetSize(width: 3840, height: 2160, snapToPatchGrid: true) ?? (0, 0)
        check.size("a snapped target needs no padding",
                   ImageBudget.paddedSize(width: aligned.width, height: aligned.height), (aligned.width, aligned.height))
        check.isTrue("a snapped target still fits", ImageBudget.fits(width: aligned.width, height: aligned.height, limits: .standard))

        // Snapping must never enlarge, and must not zero out a sub-patch axis.
        check.size("snappedToPatchGrid(1307, 20) leaves an axis under one patch alone",
                   ImageBudget.snappedToPatchGrid(width: 1307, height: 20), (1288, 20))
        check.size("scaledDown stays on the patch grid",
                   ImageBudget.scaledDown(width: 1456, height: 812, by: 0.85), (1232, 672))
        check.size("scaledDown(by: 1) is an identity, not a snap",
                   ImageBudget.scaledDown(width: 1000, height: 1000, by: 1.0), (1000, 1000))

        return check.report()
    }

    /// Accumulates failures so one run reports every broken assertion rather than
    /// stopping at the first.
    private struct Checker {
        private var passed = 0
        private var failed = 0

        mutating func equal(_ name: String, _ actual: Int, _ expected: Int) {
            record(name, actual == expected, actual: "\(actual)", expected: "\(expected)")
        }

        mutating func size(_ name: String, _ actual: (width: Int, height: Int), _ expected: (Int, Int)) {
            record(name, actual.width == expected.0 && actual.height == expected.1,
                   actual: "\(actual.width)x\(actual.height)", expected: "\(expected.0)x\(expected.1)")
        }

        mutating func optionalSize(_ name: String, _ actual: (width: Int, height: Int)?, _ expected: (Int, Int)?) {
            let matches: Bool
            switch (actual, expected) {
            case (nil, nil): matches = true
            case let (a?, e?): matches = a.width == e.0 && a.height == e.1
            default: matches = false
            }
            record(name, matches, actual: describe(actual), expected: describe(expected.map { (width: $0.0, height: $0.1) }))
        }

        mutating func isTrue(_ name: String, _ condition: Bool) {
            record(name, condition, actual: "\(condition)", expected: "true")
        }

        mutating func report() -> Bool {
            print("")
            print("\(passed) passed, \(failed) failed")
            return failed == 0
        }

        private mutating func record(_ name: String, _ ok: Bool, actual: String, expected: String) {
            if ok {
                passed += 1
                print("  ok   \(name) = \(actual)")
            } else {
                failed += 1
                print("  FAIL \(name): expected \(expected), got \(actual)")
            }
        }

        private func describe(_ size: (width: Int, height: Int)?) -> String {
            guard let size else { return "nil" }
            return "\(size.width)x\(size.height)"
        }
    }
}
