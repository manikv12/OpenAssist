import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PromptRewriteModelCatalogSmokeTests {
    static func main() {
        testFallbackCoverage()
        testOpenAICompatibleParsing()
        testOllamaTagsParsing()
        testEndpointHelpers()
        print("PASS: Prompt rewrite model catalog smoke tests passed")
    }

    private static func testFallbackCoverage() {
        for mode in PromptRewriteProviderMode.allCases {
            let fallback = PromptRewriteModelCatalogService.fallbackModels(for: mode)
            check(!fallback.isEmpty, "Fallback models should not be empty for \(mode.displayName)")
            check(
                fallback.contains(where: { $0.id.caseInsensitiveCompare(mode.defaultModel) == .orderedSame }),
                "Fallback models should include default model \(mode.defaultModel) for \(mode.displayName)"
            )
        }
    }

    private static func testOpenAICompatibleParsing() {
        let payload = """
        {
          "data": [
            { "id": "gpt-5-mini", "name": "GPT-5 Mini" },
            { "id": "gpt-4.1-mini" }
          ]
        }
        """
        let parsed = PromptRewriteModelCatalogService.parseModelOptions(from: Data(payload.utf8))
        check(parsed.count == 2, "Expected two parsed models from OpenAI payload")
        check(parsed.contains(where: { $0.id == "gpt-5-mini" }), "Missing gpt-5-mini model")
        check(parsed.contains(where: { $0.id == "gpt-4.1-mini" }), "Missing gpt-4.1-mini model")
    }

    private static func testOllamaTagsParsing() {
        let payload = """
        {
          "models": [
            { "name": "llama3.1:8b", "model": "llama3.1:8b" },
            { "name": "qwen2.5-coder:14b", "model": "qwen2.5-coder:14b" }
          ]
        }
        """
        let parsed = PromptRewriteModelCatalogService.parseModelOptions(from: Data(payload.utf8))
        check(parsed.count == 2, "Expected two parsed models from Ollama tags payload")
        check(parsed.contains(where: { $0.id == "llama3.1:8b" }), "Missing llama3.1:8b model")
        check(parsed.contains(where: { $0.id == "qwen2.5-coder:14b" }), "Missing qwen2.5-coder:14b model")
    }

    private static func testEndpointHelpers() {
        let openAIEndpoint = PromptRewriteModelCatalogService.openAIModelsEndpoint(
            from: "https://api.openai.com/v1/"
        )?.absoluteString
        check(
            openAIEndpoint == "https://api.openai.com/v1/models",
            "OpenAI models endpoint should append /models"
        )

        let anthropicEndpoint = PromptRewriteModelCatalogService.anthropicModelsEndpoint(
            from: "https://api.anthropic.com/v1"
        )?.absoluteString
        check(
            anthropicEndpoint == "https://api.anthropic.com/v1/models",
            "Anthropic models endpoint should append /models"
        )

        let googleEndpoint = PromptRewriteModelCatalogService.openAIModelsEndpoint(
            from: "https://generativelanguage.googleapis.com/v1beta/openai"
        )?.absoluteString
        check(
            googleEndpoint == "https://generativelanguage.googleapis.com/v1beta/openai/models",
            "Google Gemini models endpoint should append /models"
        )

        let ollamaEndpoint = PromptRewriteModelCatalogService.ollamaTagsEndpoint(
            from: "http://localhost:11434/v1"
        )?.absoluteString
        check(
            ollamaEndpoint == "http://localhost:11434/api/tags",
            "Ollama tags endpoint should map /v1 base to /api/tags"
        )
    }
}
