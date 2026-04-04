# AI Rewrite and Context

AI rewrite is optional in Open Assist.

You can keep text unchanged, polish it lightly, or rewrite it more strongly.

## Where to set it up

Open `Settings -> AI & Models` and:

1. turn on AI rewrite
2. choose a provider
3. pick a rewrite strength
4. open `AI Studio` if you want to manage models or local AI

You can use rewrite from the compact HUD or the full assistant window.

## Providers

- Ollama
- OpenAI
- Anthropic
- Google Gemini
- Groq
- OpenRouter

## Rewrite strengths

- `Light`: small cleanup
- `Balanced`: clearer grammar and flow
- `Strong`: heavier rewrite for a cleaner final draft

## Local AI setup

If you want a local setup with no API key:

1. Open `Settings -> AI & Models -> AI Studio`.
2. Open `Prompt Models`.
3. Choose `Local AI Setup`.
4. Install the runtime and model you want.

If local AI stops working later, use `Repair Local AI`.

## Context

Rewrite works better when you stay in the same thread, especially for longer writing or when you want a consistent tone across multiple messages.

Good starting point:

- `Balanced` rewrite
- local Ollama if you want local-only AI
- hold-to-talk if you want fast spoken text input
