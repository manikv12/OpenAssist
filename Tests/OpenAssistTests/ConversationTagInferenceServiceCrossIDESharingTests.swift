import XCTest
@testable import OpenAssist

final class ConversationTagInferenceServiceCrossIDESharingTests: XCTestCase {
    private let service = ConversationTagInferenceService.shared

    func testShouldShareCrossIDECodingContextWithMeaningfulProjectKey() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.dt.xcode",
            appName: "Xcode",
            projectKey: "project:openassist",
            featureEnabled: true
        )

        XCTAssertTrue(result)
    }

    func testShouldNotShareCrossIDECodingContextWithUnknownProjectKey() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.dt.xcode",
            appName: "Xcode",
            projectKey: "project:unknown",
            featureEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldNotShareCrossIDECodingContextWhenFeatureDisabled() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.dt.xcode",
            appName: "Xcode",
            projectKey: "project:openassist",
            featureEnabled: false
        )

        XCTAssertFalse(result)
    }

    func testShouldNotShareCrossIDECodingContextForNonCodingApp() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            projectKey: "project:openassist",
            featureEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldNotShareCrossIDECodingContextForCodex() {
        let result = service.shouldShareCrossIDECodingContext(
            bundleID: "com.openai.codex",
            appName: "Codex",
            projectKey: "project:openassist",
            featureEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldSuppressUnknownCodingHistoryForUnknownCodingContext() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.openai.codex",
            appName: "Codex",
            projectKey: "project:unknown",
            identityKey: "identity:unknown"
        )

        XCTAssertTrue(result)
    }

    func testShouldNotSuppressUnknownCodingHistoryWhenIdentityIsMeaningful() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.openai.codex",
            appName: "Codex",
            projectKey: "project:unknown",
            identityKey: "thread:bug-123"
        )

        XCTAssertFalse(result)
    }

    func testShouldNotSuppressUnknownCodingHistoryWhenProjectIsMeaningful() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.openai.codex",
            appName: "Codex",
            projectKey: "project:openassist",
            identityKey: "identity:unknown"
        )

        XCTAssertFalse(result)
    }

    func testShouldNotSuppressUnknownCodingHistoryForNonCodingApp() {
        let result = service.shouldSuppressUnknownCodingHistory(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            projectKey: "project:unknown",
            identityKey: "identity:unknown"
        )

        XCTAssertFalse(result)
    }

    func testCodexInferTagsStayAppWide() {
        let context = PromptRewriteConversationContext(
            id: "ctx-codex-tags",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Project: Open Assist | Thread: Hand off",
            fieldLabel: "Prompt"
        )

        let tags = service.inferTags(
            capturedContext: context,
            userText: "Please update workspace: Another Project and continue the Run thread."
        )

        XCTAssertEqual(tags.projectKey, "project:codex-app")
        XCTAssertEqual(tags.projectLabel, "Unknown Project")
        XCTAssertEqual(tags.identityKey, "identity:codex-app")
        XCTAssertEqual(tags.identityType, "unknown")
        XCTAssertEqual(tags.identityLabel, "Unknown Identity")
        XCTAssertEqual(tags.nativeThreadKey, "thread:codex-app")
    }

    func testCodexTupleKeyIgnoresProjectAndThreadLabels() {
        let firstContext = PromptRewriteConversationContext(
            id: "ctx-codex-1",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Run",
            fieldLabel: "Prompt"
        )
        let secondContext = PromptRewriteConversationContext(
            id: "ctx-codex-2",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Hand off",
            fieldLabel: "Another Field"
        )
        let firstTags = ConversationTupleTags(
            projectKey: "project:openassist",
            projectLabel: "Open Assist",
            identityKey: "thread:run",
            identityType: "channel",
            identityLabel: "Run",
            nativeThreadKey: "thread:run"
        )
        let secondTags = ConversationTupleTags(
            projectKey: "project:other-project",
            projectLabel: "Other Project",
            identityKey: "thread:hand-off",
            identityType: "channel",
            identityLabel: "Hand off",
            nativeThreadKey: "thread:hand-off"
        )

        let firstTuple = service.tupleKey(capturedContext: firstContext, tags: firstTags)
        let secondTuple = service.tupleKey(capturedContext: secondContext, tags: secondTags)

        XCTAssertEqual(firstTuple, secondTuple)
        XCTAssertEqual(service.threadID(for: firstTuple), service.threadID(for: secondTuple))
    }

    func testCodexContextDisplayUsesOnlyAppName() {
        let context = PromptRewriteConversationContext(
            id: "ctx-codex-display",
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            screenLabel: "Project: Open Assist | Thread: Review changes",
            fieldLabel: "Prompt",
            projectKey: "project:codex-app",
            projectLabel: "Unknown Project",
            identityKey: "identity:codex-app",
            identityType: "unknown",
            identityLabel: "Unknown Identity",
            nativeThreadKey: "thread:codex-app"
        )

        XCTAssertEqual(context.displayName, "Codex")
        XCTAssertEqual(context.providerContextLabel, "Codex")
    }

    func testAppleMessagesInfersPersonIdentityFromScreenLabel() {
        let context = PromptRewriteConversationContext(
            id: "ctx-messages",
            appName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            screenLabel: "Scott Boy - Text Message • SMS",
            fieldLabel: "Message"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.identityType, "person")
        XCTAssertEqual(tags.identityLabel, "Scott Boy")
        XCTAssertEqual(tags.identityKey, "person:scott-boy")
    }

    func testAppleMessagesInfersPersonIdentityFromSimpleHeader() {
        let context = PromptRewriteConversationContext(
            id: "ctx-messages-2",
            appName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            screenLabel: "Scott",
            fieldLabel: "Message"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.identityType, "person")
        XCTAssertEqual(tags.identityLabel, "Scott")
        XCTAssertEqual(tags.identityKey, "person:scott")
    }

    func testAppleMessagesStripsMaybePrefixFromPersonName() {
        let context = PromptRewriteConversationContext(
            id: "ctx-messages-3",
            appName: "Messages",
            bundleIdentifier: "com.apple.MobileSMS",
            screenLabel: "Maybe: Contact Person - Text Message • SMS",
            fieldLabel: "Message"
        )

        let tags = service.inferTags(capturedContext: context, userText: "")
        XCTAssertEqual(tags.identityType, "person")
        XCTAssertEqual(tags.identityLabel, "Contact Person")
        XCTAssertEqual(tags.identityKey, "person:contact-person")
    }
}
