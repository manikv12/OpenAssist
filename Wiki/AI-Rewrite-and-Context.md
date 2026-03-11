# AI Rewrite and Context

AI rewrite in Open Assist is optional and configurable. You can keep dictation raw, lightly refine it, or strongly rewrite it based on your goals.

## Supported providers

- Ollama (local)
- OpenAI
- Anthropic
- Google Gemini
- Groq
- OpenRouter

## Local AI setup (no API key)

Use built-in setup from:

`Settings -> AI Models -> AI Studio -> Prompt Models`

Then:

1. Choose a model under `Local AI Setup`.
2. Click `Install Selected Model`.
3. Complete the guided flow: `Select -> Install Runtime -> Download -> Verify -> Done`.

If local AI later fails, run `Repair Local AI` from AI Studio.

## Rewrite strength

- `Light`: minor polish, keeps original wording close
- `Balanced`: improved clarity and grammar
- `Strong`: heavier rewriting for cleaner output

## Conversation context

Open Assist can track prior turns per app/thread so rewrites are aware of what you already said.

Benefits:

- Better continuity over long sessions
- Less repetition
- More consistent tone across consecutive dictations

## Recommendation

Start with:

- `Balanced` rewrite strength
- Local Ollama provider (if you want local-only AI)
- Hold-to-talk workflow for most reliable finalization
