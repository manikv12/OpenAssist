#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SMOKE_TARGET="$(uname -m)-apple-macos13.3"

if [ ! -d "Vendor/Whisper/whisper.xcframework" ]; then
  echo "whisper.xcframework not found, downloading framework..."
  Scripts/update-whisper-framework.sh
fi

swiftc -target "$SMOKE_TARGET" \
  Sources/OpenAssist/Services/ShortcutValidationRules.swift \
  Sources/OpenAssist/Services/DictationInputModeStateMachine.swift \
  Sources/OpenAssist/Services/TextCleanup.swift \
  Sources/OpenAssist/Services/RecognitionTuning.swift \
  Sources/OpenAssist/Services/InsertionDecisionModel.swift \
  Sources/OpenAssist/Services/InsertionDiagnostics.swift \
  Sources/OpenAssist/Services/TextInserter.swift \
  Sources/OpenAssist/Services/InsertionRetryPolicy.swift \
  Scripts/CoreLogicSmokeTests.swift \
  -o /tmp/openassist-core-smoke-tests

/tmp/openassist-core-smoke-tests
Scripts/run-insertion-reliability.sh --regression

swiftc -target "$SMOKE_TARGET" \
  Sources/OpenAssist/Services/WhisperModelCatalog.swift \
  Scripts/WhisperCatalogSmokeTests.swift \
  -o /tmp/openassist-whisper-catalog-smoke-tests

/tmp/openassist-whisper-catalog-smoke-tests

swiftc -target "$SMOKE_TARGET" \
  Sources/OpenAssist/Services/ShortcutValidationRules.swift \
  Sources/OpenAssist/Support/ShortcutValidation.swift \
  Sources/OpenAssist/Support/FeatureFlags.swift \
  Sources/OpenAssist/Services/MicrophoneManager.swift \
  Sources/OpenAssist/Services/TextCleanup.swift \
  Sources/OpenAssist/Services/AdaptiveCorrectionStore.swift \
  Sources/OpenAssist/Services/CrashReporter.swift \
  Sources/OpenAssist/Services/AutomationAPIModels.swift \
  Sources/OpenAssist/Services/CodexAutomationSupport.swift \
  Sources/OpenAssist/Services/SettingsStore.swift \
  Sources/OpenAssist/Services/PromptRewriteProviderOAuthService.swift \
  Scripts/SettingsStoreWhisperSmokeTests.swift \
  -o /tmp/openassist-settings-whisper-smoke-tests

/tmp/openassist-settings-whisper-smoke-tests

swiftc -target "$SMOKE_TARGET" \
  Sources/OpenAssist/Services/ShortcutValidationRules.swift \
  Sources/OpenAssist/Support/ShortcutValidation.swift \
  Sources/OpenAssist/Support/FeatureFlags.swift \
  Sources/OpenAssist/Services/MicrophoneManager.swift \
  Sources/OpenAssist/Services/TextCleanup.swift \
  Sources/OpenAssist/Services/AdaptiveCorrectionStore.swift \
  Sources/OpenAssist/Services/CrashReporter.swift \
  Sources/OpenAssist/Services/AutomationAPIModels.swift \
  Sources/OpenAssist/Services/CodexAutomationSupport.swift \
  Sources/OpenAssist/Services/SettingsStore.swift \
  Sources/OpenAssist/Services/PromptRewriteProviderOAuthService.swift \
  Sources/OpenAssist/Assistant/AssistantMemoryModels.swift \
  Sources/OpenAssist/Services/Memory/MemoryModels.swift \
  Sources/OpenAssist/Services/Memory/MemorySQLiteStore.swift \
  Sources/OpenAssist/Services/Memory/MemoryRewriteRetrievalService.swift \
  Sources/OpenAssist/Services/Memory/MemoryRewriteExtractionProvider.swift \
  Sources/OpenAssist/Services/Memory/ConversationMemoryPromotionService.swift \
  Sources/OpenAssist/Services/ConversationTagInferenceService.swift \
  Sources/OpenAssist/Services/LocalAIRuntimeManager.swift \
  Sources/OpenAssist/Services/PromptRewriteConversationStore.swift \
  Sources/OpenAssist/Services/PromptRewriteModelCatalogService.swift \
  Sources/OpenAssist/Services/PromptRewriteService.swift \
  Scripts/PromptRewriteSmokeTests.swift \
  -o /tmp/openassist-prompt-rewrite-smoke-tests

/tmp/openassist-prompt-rewrite-smoke-tests

swiftc -target "$SMOKE_TARGET" \
  Sources/OpenAssist/Services/ShortcutValidationRules.swift \
  Sources/OpenAssist/Support/ShortcutValidation.swift \
  Sources/OpenAssist/Support/FeatureFlags.swift \
  Sources/OpenAssist/Services/MicrophoneManager.swift \
  Sources/OpenAssist/Services/TextCleanup.swift \
  Sources/OpenAssist/Services/AdaptiveCorrectionStore.swift \
  Sources/OpenAssist/Services/CrashReporter.swift \
  Sources/OpenAssist/Services/AutomationAPIModels.swift \
  Sources/OpenAssist/Services/CodexAutomationSupport.swift \
  Sources/OpenAssist/Services/SettingsStore.swift \
  Sources/OpenAssist/Services/PromptRewriteProviderOAuthService.swift \
  Sources/OpenAssist/Services/PromptRewriteModelCatalogService.swift \
  Scripts/PromptRewriteModelCatalogSmokeTests.swift \
  -o /tmp/openassist-prompt-rewrite-model-catalog-smoke-tests

/tmp/openassist-prompt-rewrite-model-catalog-smoke-tests

swiftc -target "$SMOKE_TARGET" \
  Sources/OpenAssist/Services/Memory/MemoryModels.swift \
  Sources/OpenAssist/Services/Memory/MemoryProviderDiscoveryService.swift \
  Sources/OpenAssist/Services/Memory/MemorySourceAdapters.swift \
  Sources/OpenAssist/Services/ShortcutValidationRules.swift \
  Sources/OpenAssist/Support/ShortcutValidation.swift \
  Sources/OpenAssist/Support/FeatureFlags.swift \
  Sources/OpenAssist/Services/MicrophoneManager.swift \
  Sources/OpenAssist/Services/TextCleanup.swift \
  Sources/OpenAssist/Services/AdaptiveCorrectionStore.swift \
  Sources/OpenAssist/Services/CrashReporter.swift \
  Sources/OpenAssist/Services/ConversationTagInferenceService.swift \
  Sources/OpenAssist/Services/AutomationAPIModels.swift \
  Sources/OpenAssist/Services/CodexAutomationSupport.swift \
  Sources/OpenAssist/Services/SettingsStore.swift \
  Sources/OpenAssist/Services/PromptRewriteProviderOAuthService.swift \
  Sources/OpenAssist/Services/PromptRewriteConversationStore.swift \
  Sources/OpenAssist/Assistant/AssistantMemoryModels.swift \
  Sources/OpenAssist/Services/Memory/ConversationMemoryPromotionService.swift \
  Sources/OpenAssist/Services/Memory/MemoryRewriteExtractionProvider.swift \
  Sources/OpenAssist/Services/Memory/MemorySQLiteStore.swift \
  Sources/OpenAssist/Services/Memory/MemoryIndexingService.swift \
  Scripts/MemoryIndexingSmokeTests.swift \
  -o /tmp/openassist-memory-indexing-smoke-tests

/tmp/openassist-memory-indexing-smoke-tests
