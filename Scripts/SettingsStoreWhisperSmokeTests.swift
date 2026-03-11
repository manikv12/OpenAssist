import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("❌ \(message)\n", stderr)
        exit(1)
    }
}

@main
struct SettingsStoreWhisperSmokeTests {
    static func main() async {
        let settings = await MainActor.run { SettingsStore.shared }

        let originalEngine = await MainActor.run { settings.transcriptionEngineRawValue }
        let originalModelID = await MainActor.run { settings.selectedWhisperModelID }
        let originalUseCoreML = await MainActor.run { settings.whisperUseCoreML }
        let originalMemoryIndexingEnabled = await MainActor.run { settings.memoryIndexingEnabled }
        let originalMemoryCatalogAutoUpdate = await MainActor.run { settings.memoryProviderCatalogAutoUpdate }
        let originalDetectedProviderIDs = await MainActor.run { settings.memoryDetectedProviderIDs }
        let originalEnabledProviderIDs = await MainActor.run { settings.memoryEnabledProviderIDs }
        let originalDetectedSourceFolderIDs = await MainActor.run { settings.memoryDetectedSourceFolderIDs }
        let originalEnabledSourceFolderIDs = await MainActor.run { settings.memoryEnabledSourceFolderIDs }

        await MainActor.run {
            check(TranscriptionEngineType(rawValue: settings.transcriptionEngineRawValue) != nil, "Default engine should be valid")

            settings.transcriptionEngine = .whisperCpp
            settings.selectedWhisperModelID = "tiny.en"
            settings.whisperUseCoreML = false

            check(settings.transcriptionEngine == .whisperCpp, "Engine setter should persist whisper.cpp")
            check(settings.selectedWhisperModelID == "tiny.en", "Selected whisper model should persist")
            check(settings.whisperUseCoreML == false, "Core ML toggle should persist")

            let defaults = UserDefaults.standard
            check(
                defaults.string(forKey: "OpenAssist.transcriptionEngine") == TranscriptionEngineType.whisperCpp.rawValue,
                "Engine key should be saved in UserDefaults"
            )
            check(
                defaults.string(forKey: "OpenAssist.selectedWhisperModelID") == "tiny.en",
                "Selected model key should be saved in UserDefaults"
            )
            check(
                defaults.bool(forKey: "OpenAssist.whisperUseCoreML") == false,
                "Core ML key should be saved in UserDefaults"
            )

            settings.transcriptionEngineRawValue = "invalid-engine"
            check(settings.transcriptionEngine == .appleSpeech, "Invalid engine raw value should fall back to Apple Speech")

            settings.memoryIndexingEnabled = true
            settings.memoryProviderCatalogAutoUpdate = false
            settings.updateDetectedMemoryProviders(["transcript-history", "custom-phrases"])
            settings.setMemoryProviderEnabled("custom-phrases", enabled: false)
            settings.updateDetectedMemoryProviders(["transcript-history", "custom-phrases", "learned-corrections"])

            check(settings.memoryIndexingEnabled == true, "Memory indexing master toggle should persist")
            check(settings.memoryProviderCatalogAutoUpdate == false, "Memory provider catalog auto-update should persist")
            check(
                settings.memoryDetectedProviderIDs == ["custom-phrases", "learned-corrections", "transcript-history"],
                "Detected providers should be normalized and saved"
            )
            check(
                settings.memoryEnabledProviderIDs == ["learned-corrections", "transcript-history"],
                "Disabled providers should stay disabled and new providers should default enabled"
            )
            check(
                settings.isMemoryProviderEnabled("learned-corrections"),
                "Newly detected provider should be enabled"
            )
            check(
                !settings.isMemoryProviderEnabled("custom-phrases"),
                "Explicitly disabled provider should remain disabled"
            )

            settings.updateDetectedMemorySourceFolders(["/tmp/openassist-a", "/tmp/openassist-b"])
            settings.setMemorySourceFolderEnabled("/tmp/openassist-b", enabled: false)
            settings.updateDetectedMemorySourceFolders(["/tmp/openassist-a", "/tmp/openassist-b", "/tmp/openassist-c"])

            check(
                settings.memoryDetectedSourceFolderIDs == ["/tmp/openassist-a", "/tmp/openassist-b", "/tmp/openassist-c"],
                "Detected source folders should be normalized and saved"
            )
            check(
                settings.memoryEnabledSourceFolderIDs == ["/tmp/openassist-a", "/tmp/openassist-c"],
                "Disabled source folders should stay disabled and new folders should default enabled"
            )
            check(
                settings.isMemorySourceFolderEnabled("/tmp/openassist-c"),
                "Newly detected source folder should be enabled"
            )
            check(
                !settings.isMemorySourceFolderEnabled("/tmp/openassist-b"),
                "Explicitly disabled source folder should remain disabled"
            )

            check(
                defaults.bool(forKey: "OpenAssist.memoryIndexingEnabled"),
                "Memory indexing key should be saved in UserDefaults"
            )
            check(
                defaults.bool(forKey: "OpenAssist.memoryProviderCatalogAutoUpdate") == false,
                "Memory catalog auto-update key should be saved in UserDefaults"
            )
            check(
                defaults.stringArray(forKey: "OpenAssist.memoryEnabledProviderIDs") == ["learned-corrections", "transcript-history"],
                "Enabled provider IDs key should be saved in UserDefaults"
            )
            check(
                defaults.stringArray(forKey: "OpenAssist.memoryEnabledSourceFolderIDs") == ["/tmp/openassist-a", "/tmp/openassist-c"],
                "Enabled source folder IDs key should be saved in UserDefaults"
            )

            testAdaptiveCorrectionAmbiguousMergeAutoApplyGating()
        }

        await MainActor.run {
            settings.transcriptionEngineRawValue = originalEngine
            settings.selectedWhisperModelID = originalModelID
            settings.whisperUseCoreML = originalUseCoreML
            settings.memoryIndexingEnabled = originalMemoryIndexingEnabled
            settings.memoryProviderCatalogAutoUpdate = originalMemoryCatalogAutoUpdate
            settings.memoryDetectedProviderIDs = originalDetectedProviderIDs
            settings.memoryEnabledProviderIDs = originalEnabledProviderIDs
            settings.memoryDetectedSourceFolderIDs = originalDetectedSourceFolderIDs
            settings.memoryEnabledSourceFolderIDs = originalEnabledSourceFolderIDs
        }

        print("✅ Settings store whisper smoke tests passed")
    }

    @MainActor
    private static func testAdaptiveCorrectionAmbiguousMergeAutoApplyGating() {
        let now = Date()

        let singleLearnStore = AdaptiveCorrectionStore.inMemoryStoreForSmokeTests(
            seedCorrections: [
                .init(source: "time of", replacement: "timeoff", learnCount: 1, updatedAt: now)
            ]
        )
        let singleLearnResult = singleLearnStore.applyWithEvents(to: "what time of day is it")
        check(
            singleLearnResult.text == "what time of day is it",
            "Ambiguous merged corrections should not auto-apply after a single learn"
        )
        check(
            singleLearnResult.appliedEvents.isEmpty,
            "Ambiguous merged corrections should not report applied events after a single learn"
        )

        let repeatedLearnStore = AdaptiveCorrectionStore.inMemoryStoreForSmokeTests(
            seedCorrections: [
                .init(source: "time of", replacement: "timeoff", learnCount: 2, updatedAt: now)
            ]
        )
        let repeatedLearnResult = repeatedLearnStore.applyWithEvents(to: "need time of tomorrow")
        check(
            repeatedLearnResult.text == "need timeoff tomorrow",
            "Ambiguous merged corrections should auto-apply after repeated learns"
        )
        check(
            repeatedLearnResult.appliedEvents.count == 1,
            "Ambiguous merged corrections should emit an applied event once they are trusted"
        )

        let typoStore = AdaptiveCorrectionStore.inMemoryStoreForSmokeTests(
            seedCorrections: [
                .init(source: "teh", replacement: "the", learnCount: 1, updatedAt: now)
            ]
        )
        let typoResult = typoStore.applyWithEvents(to: "teh cat")
        check(
            typoResult.text == "the cat",
            "Non-ambiguous single-word corrections should still auto-apply at learn count 1"
        )

        let manualStore = AdaptiveCorrectionStore.inMemoryStoreForSmokeTests()
        guard let manualCorrection = manualStore.upsertManualCorrection(source: "time of", replacement: "timeoff") else {
            check(false, "Manual correction should be accepted for valid input")
            return
        }
        check(
            manualCorrection.learnCount >= 2,
            "Manual corrections should be trusted immediately to avoid extra confirmation loops"
        )
        let manualResult = manualStore.applyWithEvents(to: "need time of tomorrow")
        check(
            manualResult.text == "need timeoff tomorrow",
            "Manual corrections should auto-apply immediately even for ambiguous merged phrases"
        )
    }
}
