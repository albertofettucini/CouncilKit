# Changelog

CouncilKit is pre-1.0, so a minor or patch release can change the public API. Pin to a minor
(`.upToNextMinor(from:)`) and read this before moving up.

## 0.3.2

Ships with Council 1.3.2. The theme: an answer that did not finish is never recorded as a whole one.

**Changes you may have to act on**

- `StreamChunk` has two new cases, `.stop(StopReason)` and `.heartbeat`. An exhaustive `switch`
  over it stops compiling: add both. `.stop` says why the provider ended the response;
  `.heartbeat` means it sent something that is not answer text (thinking, a ping, a keep-alive).
- `CouncilStore()` loads the saved history only inside the Council app. Any other host starts
  empty unless it passes `loadHistory: true`, so the CLI and the facade no longer read (or replay)
  sessions they did not create.
- The synthesis no longer recommends an answer. It says what the council settled, what is still
  yours to decide, and where they diverged. `CouncilKit.promptVersion` is 3 (peer review changed at
  2: reviewers now read the question, the seat's persona and the round's kept document).
- Claude calls send `max_tokens` 16000 when the seat sets none (it was 8192), because on the
  models that think first the cap covers the thinking too.
- On OpenAI-compatible backends the one-shot verdict call asks for 1500 tokens (it was 400) and
  waits up to 120 seconds, for the same reason: a model that reasons first spends part of the cap
  before the first brace.

**New**

- Each answer has a status: `complete`, `truncated` (cut off at the length limit), `stalled`,
  `cancelled` or `failed`. `Answer.status` carries it in `deliberate`; `stream` has no event for it.
- An incomplete answer sits out of peer review, the divergence score and the dissent unless it is
  put back with `setDeliberationSelection`, and it is not replayed as context on the next turn.
- A round records the model that wrote each answer, the prompt version and when it was asked.
- `CouncilLimits.thinkingTimeoutSeconds` (600): how long a call may show signs of life without
  adding to its answer. `stallTimeoutSeconds` (90) still bounds a call that sends nothing at all.
- `LLMProvider.current(_:)` maps a model id a provider no longer serves to the one that answers in
  its place (`deepseek-chat` → `deepseek-flash`, and a few more). Saved seats and imported lineups
  go through it. The default DeepSeek and Gemini models moved to `deepseek-flash` and
  `gemini-3.6-flash`; the suggestion lists were refreshed for every hosted provider.
- `council --json` gains `answerStatus`, `stages`, `seats[].status`, `seats[].recordedModel` and
  `dissent.status`. The schema stays `council.cli.v1`; nothing was renamed or removed.
- `--deliberate` accepts the names a run prints (`"ollama (2)"`), and a repeated provider name
  takes that provider's seats in order.

**Fixed**

- Stop saved a half-written answer as a complete one.
- A stream that ended without its end signal was recorded as done (Claude, OpenAI, Gemini and
  OpenRouter, which always send one; other hosts are not promised to, so they are left unmarked).
- A failure reported inside a stream that began with HTTP 200 now fails the call with the
  provider's message instead of keeping the text so far.
- An empty `finish_reason` on every chunk no longer hides the real one.
- Thinking, pings and keep-alives count as signs of life, so a model that reasons past the stall
  limit before its first word is not cut off.
- Mistral's reasoning models send `content` as a list of parts while they think; the thinking is
  left out and the answer's first words are kept.
- Claude gets a `temperature` only on the 4.5 and 4.6 families; every other Claude id gets none
  (Opus 4.7 and later refuse it). OpenAI's GPT-6 ids get none either, and OpenAI's own API gets
  the cap as `max_completion_tokens`.
- Two seats on one provider no longer overwrite each other in the CLI's JSON, and
  `divergence.outlier`, `dissent.name` and `deliberatedSeats` use the same names as the `answers` keys.
