# AI Rewrite and Context

AI rewrite in Open Assist is optional.

You can keep text raw, lightly polish it, or rewrite it more strongly depending on the situation.

## Where to set it up

Open `Settings -> AI & Models` and then:

1. Turn on AI rewrite.
2. Choose a provider.
3. Pick a rewrite strength.
4. Open `AI Studio` if you want to manage models or local AI.

You can use rewrite from the compact HUD or the full assistant window.

## Supported providers

- Ollama for local use
- OpenAI
- Anthropic
- Google Gemini
- Groq
- OpenRouter

## Rewrite strength

- `Light`: small cleanup that keeps your wording close
- `Balanced`: clearer text with better grammar and flow
- `Strong`: heavier rewrite for a cleaner final draft

## Local AI setup

If you want no API key, use the built-in setup:

1. Open `Settings -> AI & Models -> AI Studio`.
2. Open `Prompt Models`.
3. Choose `Local AI Setup`.
4. Install the runtime and the model you want.
5. Verify the setup when the app finishes.

If local AI fails later, use `Repair Local AI` from AI Studio.

## Context and memory

Open Assist can keep context across turns so rewrites stay consistent.

That helps when you:

- keep working in the same thread
- write longer messages or documents
- want the same tone across several replies

Helpful note:

- assistant memory and voice dictation history are separate
- you can still keep text raw if you do not want rewriting

## Good starting point

Start with:

- `Balanced` rewrite strength
- Local Ollama if you want a local-only setup
- Hold-to-talk for the most reliable final text
