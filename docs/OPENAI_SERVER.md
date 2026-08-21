# Local OpenAI-compatible server

`TurboFieldfareServer` exposes a local Chat Completions API for one Gemma
model. It binds to `127.0.0.1` without authentication or TLS. Do not expose it
through a proxy or tunnel.

For the M3 Pro this branch targets, [`SERVER_RUNBOOK.md`](SERVER_RUNBOOK.md)
(Japanese) has the exact commands, the context/slot combinations that fit in
its Metal working set, and the measured numbers.

## Start the server

First, install the model with the Mac app or `TurboFieldfareRepack`. Then check
that no other TurboFieldfare model process is running:

```bash
pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'
```

If the command prints a match, do not start the server.

```bash
swift build -c release --product TurboFieldfareServer
.build/release/TurboFieldfareServer \
  --model scratch/gemma4.gturbo \
  --port 8080 \
  --ctx-size 16384
```

The server opens the port first and loads the model behind it. While the load
runs, every endpoint answers 503 `unavailable_error` with `code:
"model_loading"`, so a client can tell "still loading" apart from "not running"
— connection refused now means the process is not up. `GET /health` returns
`{"status":"ok"}` once the model is ready. If the load fails, the process
prints the reason to stderr and exits 1, so the port closes again. Keep the
process running while clients use it.

Check the server from another terminal:

```bash
curl --silent --show-error http://127.0.0.1:8080/health
curl --silent --show-error http://127.0.0.1:8080/v1/models
curl --silent --show-error http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma-4-26b-a4b-it",
    "messages": [{"role": "user", "content": "Reply with exactly READY."}],
    "temperature": 0,
    "max_completion_tokens": 16
  }'
```

By default, the server runs one generation and admits up to four additional
requests for preparation or queueing. The limit is enforced before prompt
rendering and tokenization. Use `--queue-limit` to change it. Press Control-C
to stop the server.

## Runtime settings

The server accepts the same runtime flags as the CLI, with the same values and
defaults. See [Runtime controls](RUNTIME_CONTROLS.md) for what each one does.

```bash
.build/release/TurboFieldfareServer \
  --model scratch/gemma4.gturbo \
  --expert-cache-slots 32 \
  --expert-cache-policy lru \
  --prefill on \
  --prefill-chunk-tokens 64 \
  --rdadvise bounded
```

Without these flags the server runs the production defaults: 48 expert-cache
slots, LFU eviction, chunked prefill on with 2048-token chunks, and read advice
off. Values are validated before the model loads, so an unusable one exits with
the usage text rather than failing partway through startup — but `-c/--ctx-size`
and `--expert-cache-slots` are **rounded down** to a value this machine can hold
rather than refused, and `/props` reports the effective `n_ctx`. Chunked prefill
needs at least 16 expert-cache slots, so `--expert-cache-slots 8` requires
`--prefill off`.

Four flags govern the surface rather than the model:

| Flag | Default | What it does |
| --- | --- | --- |
| `--api-key <key>[,<key>]` | none | Requires `Authorization: Bearer <key>` (or `X-Api-Key`) on everything except `/health` and `/v1/models`. Repeat the flag to add more keys. |
| `--cors-origins <origin>[,<origin>]` | none | Sends CORS headers for those origins only. With no flag the server sends none, and the 127.0.0.1 bind is the whole defence. |
| `--slots` / `--no-slots` | on | Whether `GET /slots` answers. |
| `--metrics` | off | Whether `GET /metrics` answers. |

The settings are fixed for the life of the process. Restart the server to
change them.

## Speculative decoding (MTP)

If the model was installed with the drafter section (`--include-draft`, or
`--add-draft` on an existing install), `--draft-block-size` turns on multi-token
prediction:

```bash
.build/release/TurboFieldfareServer \
  --model scratch/gemma4-qat-sym.gturbo \
  --expert-cache-slots 32 \
  --draft-block-size 4
```

Every accepted token is a token the target model itself drew at the same
sampler position, so the answer is the answer of the non-speculative run and
only the wall clock changes. Measured on this server with 4-token blocks:
about **1.4x** on a coding answer with tools declared, and about **1.0x** on
Japanese prose, which the drafter predicts far less well
(`docs/mtp/26-M6-RESULTS.md`).

The flag needs `--prefill on` (the default) and a model with the drafter
section; either missing exits at startup rather than failing on the first
request. Prompt reuse is unaffected: `cached_tokens` is the same with the flag
on and off.

Declaring `tools` — or a `response_format`, or any `tool_choice` — does **not**
turn speculation off. A constrained request is drawn one position at a time with
the grammar applied and verified the same way an unconstrained one is
(SPEC §6 GEN-14). Two kinds of request still run on the plain decode path for
that request alone: one asking for a `repeat_penalty` other than `1.0`, and one
whose thought channel is open *and* bounded, because the closing tag the budget
forces is a token that was placed rather than drawn (SPEC §12 DEV-14).

"Bounded" is measured against what the context has left, not against whether the
field was written: a `max_tokens` at or above the remaining context bounds
nothing that `max_tokens: -1` would not bound, so it sets no deadline and the
request keeps speculating (SPEC §8 RSN-4). A client that simply echoes the
model's advertised limit — most do — is therefore not giving up MTP by sending
it. A `reasoning_budget_tokens`, or a `max_tokens` genuinely shorter than the
remaining context, does set one.

**To see whether it ran**, read `timings.draft_n` on the response: it is the
number of tokens the drafter proposed, and `timings.draft_n_accepted` how many
the target agreed with. Both keys are **absent** from a request that did not
speculate, so "no keys" and "ran but accepted nothing" are different answers.

Each completed request logs what the round bookkeeping saw:

```
request chatcmpl-… completed in 18.264s prompt=208 cached=0 completion=600 finish=length mtp=4 rounds=179 accept=2.346
```

`accept` is the mean number of accepted drafts per round; `mtp` is the block
width. They say how the wall clock was spent, never what the answer was.

## Reasoning

The chat template has a thought channel. With it closed the model answers
directly; with it open the model reasons first and the reasoning comes back in
its own response field, never mixed into the answer.

Reasoning is the process default. `--reasoning-budget` decides how much of it
there is: `-1` (the default) is unlimited, `0` closes the channel entirely, and
a positive number caps the thought at that many tokens. When the cap is reached
— or when `max_tokens` leaves too little room for an answer — the server forces
the closing tag into the stream so the model leaves the thought channel and
writes an answer. It does not hand back a full `reasoning_content` with an
empty `content`.

```bash
# no reasoning at all
.build/release/TurboFieldfareServer \
  --model scratch/gemma4-qat-sym.gturbo \
  --reasoning-budget 0
```

`--reasoning-format` decides where the thought goes: `auto` (the default) puts
it in `reasoning_content`, and `none` leaves it in `content` as raw text.

The old `--thinking on|off` flag is gone; the server refuses it by name and
tells you to use `--reasoning-budget`. Note the change of default that comes
with it: `--thinking` defaulted to **off**, `--reasoning-budget` defaults to
**unlimited**, so a client that says nothing now reasons.

A request overrides the default in either of the two spellings clients use:

```bash
curl --silent --show-error http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma-4-26b-a4b-it",
    "messages": [{"role": "user", "content": "9.11 と 9.9 はどちらが大きい?"}],
    "chat_template_kwargs": {"enable_thinking": true}
  }'
```

`{"reasoning_effort": "medium"}` does the same. The template has one thought
channel and no budget, so an effort level is read only for its on/off sense:
`none` and `off` mean no reasoning, `minimal`, `low`, `medium`, `high`, and
`max` mean reasoning. Sending both spellings with opposite answers is a 400.

The reasoning arrives as `reasoning_content` — in `choices[0].message` for a
JSON response, in `choices[0].delta` for SSE, and absent entirely when the
request did not reason. It is generated text like any other: its tokens are
counted in `completion_tokens` and spend the same `max_tokens` budget. A `stop`
string is matched against the answer only.

Reasoning works alongside function tools and images: a request may declare
tools, attach a picture, and ask to reason, and the answer comes back with the
tool calls it decided on, the reasoning separated out, or both.

Prompt reuse works the same with reasoning on: a follow-up turn resumes from
the cached prefix and prefills only what the turn added. Reuse is decided by
the longest common prefix of the token sequences and by nothing else, so
switching reasoning on or off mid conversation simply shortens that prefix at
the point where the rendering changes. Hand the reasoning back in
`reasoning_content` and the prefix survives the turn; drop it and the turn that
produced it is prefilled again. A caller that wants no reuse at all sends
`cache_prompt: false`.

## Connect a client

The base URL is `http://127.0.0.1:8080/v1`. Some client libraries require an
API key, but the server ignores it.

Python:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="local")
response = client.chat.completions.create(
    model="gemma-4-26b-a4b-it",
    messages=[{"role": "user", "content": "Say hello in one sentence."}],
)
print(response.choices[0].message.content)
```

OpenCode:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "turbofieldfare": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "TurboFieldfare",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1",
        "apiKey": "local"
      },
      "models": {
        "gemma-4-26b-a4b-it": {
          "name": "Gemma 4 26B-A4B IT",
          "limit": {
            "context": 16384,
            "output": 4096
          }
        }
      }
    }
  }
}
```

Select `turbofieldfare/gemma-4-26b-a4b-it` in OpenCode.

Pi uses its `openai-completions` adapter:

```json
{
  "providers": {
    "turbofieldfare": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsReasoningEffort": false,
        "supportsStrictMode": false,
        "supportsUsageInStreaming": true,
        "thinkingFormat": "qwen-chat-template"
      },
      "models": [{
        "id": "gemma-4-26b-a4b-it",
        "name": "Gemma 4 26B-A4B IT",
        "reasoning": true,
        "contextWindow": 16384,
        "maxTokens": 4096
      }]
    }
  }
}
```

`"reasoning": true` with `"thinkingFormat": "qwen-chat-template"` is what makes
pi's thinking toggle send `chat_template_kwargs.enable_thinking`, which this
server reads; it also reads `reasoning_content` back out of the response. Leave
`"reasoning": false` if you would rather drive reasoning from the server's
`--reasoning-budget` flag. Pi declares its built-in tools on every request of an
interactive session, which the server no longer treats as a reason to skip
reasoning, so the toggle works in an ordinary session.

Keep the client context setting at or below the server's `-c/--ctx-size`.

## Images

A model installed with a vision tower accepts images as `image_url` content
parts on user messages. Install the tower with
`TurboFieldfareRepack --add-vision --input-gturbo <model.gturbo>`; a model
without one answers image requests with HTTP 400 and `vision_not_installed`.

```bash
curl --silent --show-error http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma-4-26b-a4b-it",
    "messages": [{"role": "user", "content": [
      {"type": "text", "text": "What is in this picture?"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
    ]}],
    "temperature": 0.2,
    "max_completion_tokens": 256
  }'
```

**Only `data:` URIs are accepted.** The server never fetches an image URL: an
`http(s)` or `file` URL returns HTTP 400 with `unsupported_image_url`. Fetching
a caller-supplied URL would make the server issue requests on behalf of whoever
can reach it, and a local inference server has no reason to do that.

Limits, all configurable at startup:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--image-tokens` | 280 | Soft-token budget per image: 70, 140, or 280 |
| `--max-images` | 4 | Images per request |
| `--max-image-bytes` | 8388608 | Decoded bytes per image |
| `--max-image-pixels` | 50000000 | Pixels per image, read from the header |

Exceeding a limit returns HTTP 400 `invalid_request_error` (`image_too_large`,
`too_many_images`, or `request_too_large` for the body ceiling). The server
never answers 413 — see [SPEC §12 DEV-11](serving/SPEC.md). The request-body
ceiling rises with `--max-images` and `--max-image-bytes`, so base64 payloads
within the limits are not cut off by the transport.

`--image-tokens` is an upper bound, not the count. Each image is resized to a
whole number of 48-pixel cells, so the soft tokens it occupies follow its aspect
ratio: 256 for a square image at the default budget, 266 for a 4:3 one. Those
tokens are part of `usage.prompt_tokens`.

Images may be sent alongside `tools`: the tool-calling template renders an
image content part with the same `<|image|>` marker the text template uses, so
an interactive session that declares tools every turn can still show the model
a picture. One condition is refused rather than approximated: images while the
server runs `--prefill off`, since the unchunked path has nowhere to place a
soft token.

Prompt reuse works across images: a conversation that showed a picture resumes
from its cached prefix on the next turn, and a turn that adds another picture
prefills only what it added. The cache carries a digest per image, so two
requests with the same words and different pictures do not share a prefix.

Audio and video are not supported. Writing `<|image|>`, `<|audio|>`, or
`<|video|>` into message text is an error, not a silent pass-through.

## Prompt reuse

Single-prefix KV reuse is on by default. Send the complete message history with
every request. When a request continues the retained conversation exactly, the
server reuses the verified KV prefix and reports the number of reused tokens in:

```text
usage.prompt_tokens_details.cached_tokens
```

The server retains one prefix. A history that diverges from it is served up to
the point where it diverges and prefilled from there — unless the divergence is
more than 2048 tokens back from the end of the cached prefix, which is as far
as the KV cursor may move (SPEC §12 DEV-13); past that the prompt is prefilled
whole. Send `cache_prompt: false` to opt a request out of reuse entirely.

## Tool calls

The server can return OpenAI-style function calls, but it cannot authorize or
execute them. The client runs the tool loop:

1. Send function schemas in `tools`.
2. When `finish_reason` is `"tool_calls"`, inspect each function name and JSON
   argument object. Apply the client's normal permission checks before running
   the function.
3. Append the assistant message, including its unchanged `tool_calls`.
4. Append each result as a `role: "tool"` message. Its `tool_call_id` must
   match the call it resolves.
5. Send the complete history and tool schemas again.

The server accepts only function tools. Omit `tool_choice` or set it to `auto`
to allow calls. Set it to `none` to disable them. The server does not support
`required`, named tool selection, or `parallel_tool_calls: false`.

Tool schemas need a non-null object at the top level and explicit JSON Schema
types. Nested properties and items may use nullable forms with one concrete
type plus `null`, including equivalent two-branch `anyOf` and disjoint `oneOf`
forms. Unions of string constants are also supported. Overlapping `oneOf`,
mixed-type unions such as `string | object`, and `allOf` return HTTP 400 with
`invalid_tool_schema`; the server does not guess which branch the model should
use.

## Supported API

Endpoints:

- `GET /health`, `GET /v1/health`
- `GET /v1/models`, `GET /models`
- `POST /v1/chat/completions`, `POST /chat/completions`
- `GET /props` — the effective defaults, the context length actually in force,
  the chat template, `build_info`, and `modalities`. A client that wants to know
  what this server can do reads this rather than guessing.
- `POST /tokenize`, `POST /detokenize`, `POST /apply-template` — token counts
  before you send, and the exact prompt this server would render for a
  conversation. `/apply-template` renders with the template the server actually
  uses, not the one bundled with the model.
- `GET /slots`, `GET /metrics` — whether the one generation slot is busy, and
  cumulative token/second counters in Prometheus text format. **Both are gated
  at startup**: `/slots` is on unless you pass `--no-slots`, `/metrics` is off
  unless you pass `--metrics`. A gated-off endpoint answers 501 and names the
  flag that opens it.

A path this server knowingly does not serve — `/v1/embeddings`, `/v1/responses`,
`/v1/completions` and the rest of the list in
[SPEC §3](serving/SPEC.md) — answers **501** `not_supported_error`, as does an
endpoint whose startup flag is off. Only a path that means nothing here is a 404.

Every response carries `system_fingerprint`, which identifies the running
build and is the same string `/props` reports as `build_info`. Every response
also carries `timings` — the prompt and prediction token counts, milliseconds,
and rates — on the non-stream body and on the last SSE chunk; send
`"timings_per_token": true` to get one on every chunk. Context usage is
`timings.prompt_n + timings.cache_n + timings.predicted_n`. A request that ran
speculative decoding also carries `draft_n` and `draft_n_accepted` there; a
request that did not carries neither key (see
[Speculative decoding](#speculative-decoding-mtp)).

Chat Completions supports JSON and Server-Sent Events responses. Set
`"stream": true` for streaming. Set
`"stream_options": {"include_usage": true}` to receive a final usage chunk.

Requests may contain system, developer, user, assistant, and tool messages.
Message content may be a string or a list of `text` and `image_url` parts.
Supported options include `temperature`, `top_p`, `top_k`,
`repeat_penalty`, `seed`, `stop`, `max_tokens`,
`max_completion_tokens`, `n`, `cache_prompt`, `reasoning_effort`,
`reasoning_budget_tokens`, `reasoning_format`,
`chat_template_kwargs.enable_thinking`, and function-tool fields.
Responses carry `reasoning_content` when the request reasoned.

The accepted values of every one of those fields are
[SPEC §4](serving/SPEC.md); that table is the contract, and this page only
summarises it. Three rules are worth stating here because clients rely on
them: an unknown field is ignored rather than refused, `null` means "use the
default", and a sampling value outside its range is clamped rather than
rejected. `model` is not checked — the name you send is the name that comes
back. A parameter the server cannot honor is answered with 501
`not_supported_error`, never with a 200 in the wrong shape: today that is
`logprobs` alone.

**Structured output and forced tool calls are grammar-constrained**, not
best-effort. `response_format` `json_object` and `json_schema`, and
`tool_choice` `required` and `{"type":"function","function":{"name":…}}`, all
constrain generation token by token, so the body comes back in the shape you
asked for. A schema element that cannot be expressed is **approximated, never
refused** — a generated schema with one unrepresentable line at its edge still
runs, and what was given up is reported on the request's `completed` line as
`approx=`. What cannot be combined is refused rather than half-honored: a
non-`text` `response_format` together with `tool_choice` `required` or a named
function is a 400, as is a named `tool_choice` for a tool the request did not
declare, and `required` with no tools.

The server supports one model and one choice. Images are supported as described
above; audio and video are not. It does not support the Responses API, legacy
Completions, embeddings, batching, log probabilities, or remote model
switching.

Context length can be 4K, 8K, 16K, 32K, 64K, or 128K. The default is 16K. Only
the full-attention layers grow with the context — the sliding-window layers are
capped by their ring — but those layers grow linearly: on the pinned checkpoint
the FP16 KV cache measures 1.97 GB at 64K and 3.31 GB at 128K. That comes out of
the same Metal working set as the expert cache, so a long context needs fewer
`--expert-cache-slots`; a combination the device cannot keep resident is
rejected at load with the arithmetic printed. On an 8 GB Mac, run one model
process at a time and watch memory pressure.

For long requests, stderr reports the request lifecycle as prepared, queued,
generating, completed, or failed. It includes token counts and timing, but not
prompt text, tool arguments, headers, or request bodies. How much of a prompt
was served from the cache is the `cached=` count on the completed line, which
is the same number as `usage.prompt_tokens_details.cached_tokens`.
