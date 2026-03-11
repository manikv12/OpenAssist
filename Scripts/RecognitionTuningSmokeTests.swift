import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("❌ \(message)\n", stderr)
        exit(1)
    }
}

@main
struct RecognitionTuningSmokeTests {
    static func main() {
        check(abs(RecognitionTuning.clampedFinalizeDelay(0.01) - 0.15) < 0.0001, "Delay lower clamp failed")
        check(abs(RecognitionTuning.clampedFinalizeDelay(0.35) - 0.35) < 0.0001, "Delay nominal value failed")
        check(abs(RecognitionTuning.clampedFinalizeDelay(9.0) - 1.2) < 0.0001, "Delay upper clamp failed")

        let parsed = RecognitionTuning.parseCustomPhrases("alpha, beta\n gamma\n\n,delta")
        check(parsed == ["alpha", "beta", "gamma", "delta"], "Phrase parsing failed")

        let better = RecognitionTuning.chooseBetterTranscript(primary: "hello", fallback: "hello world from openassist")
        check(better == "hello world from openassist", "Best transcript selection failed")

        let hints = RecognitionTuning.contextualHints(defaults: ["OpenAssist", "dictation", "macOS"], custom: ["dictation", "custom"], limit: 4)
        check(hints.count <= 4, "Hints limit failed")
        check(Set(hints).contains("custom"), "Hints custom merge failed")

        print("✅ Recognition tuning smoke tests passed")
    }
}
