# Item Chat Design

Per-item chat: ask questions about an archived item's content, backed by an
OpenAI-compatible LLM. Replaces the existing "Chat coming soon" placeholder in
`ItemDetailLive`.

## Goals

- Let users ask freeform questions about an item (article, video transcript,
  podcast transcript, etc.) without leaving the item detail page.
- Preserve conversation history across page reloads.
- Keep the system prompt regenerable so it always reflects current config and
  current item content.

## Non-goals

- Multiple named conversations per item (single `chat.jsonl` for now; revisit
  if warranted).
- Streaming token output (single-shot, render on completion).
- Cross-item / global chat.
- Sharing or exporting conversations.

## Storage

- File: `<item.archive_path>/chat.jsonl`.
- One JSON object per line, one line per turn.
- Schema: `{"role": "user" | "assistant", "content": "...", "ts": "<ISO8601>"}`.
- The **system prompt is never persisted**. On every load and every new turn,
  the prompt is rebuilt from current config and current item content. Users
  can edit the prompt template and resume an existing conversation under the
  new prompt.
- On send: append user turn → call LLM with
  `[system_prompt, ...history, user_turn]` → append assistant turn on success.
- Malformed lines are logged and skipped on load (forward compatibility,
  partial-write tolerance).

## Content selection

`Cham.Chat.resolve_content(item, artifacts)` returns `{content, source_label}`
where `source_label` is one of `"article"`, `"transcript"`, `"summary"`,
or `nil` (no usable content).

Priority:

1. Primary content — the derived/original `content` artifact (articles) or the
   derived `transcript` artifact (videos, podcasts).
2. Fall back to the `summary` artifact if neither is available.
3. Otherwise no content; chat input is hidden and an empty state is shown.

Content is truncated to `max_input_tokens * 4` characters before being
substituted into the system prompt. The default `max_input_tokens` (32000) is
chosen so that for typical content neither chat nor summarization hits the
limit; users can tune it.

## Module: `Cham.Chat`

```elixir
@spec load_history(Item.t()) :: [%{role: String.t(), content: String.t(), ts: String.t()}]
@spec append_turn(Item.t(), String.t(), String.t()) :: :ok | {:error, term()}
@spec resolve_content(Item.t(), [Artifact.t()]) :: {String.t() | nil, String.t() | nil}
@spec build_system_prompt(Item.t(), String.t()) :: String.t()
@spec send_message(Item.t(), [Artifact.t()], String.t()) ::
        {:ok, [turn]} | {:error, term()}
```

`send_message/3` is the orchestrator:

1. `resolve_content/2`; if no content, return `{:error, :no_content}`.
2. Truncate content, `build_system_prompt/2`.
3. `load_history/1`, append the user turn to filesystem, build the
   `[system, ...history, user]` message list.
4. `Cham.LLM.Provider.generate/3` (using the existing OpenAI adapter).
5. On success, append assistant turn to filesystem, return updated history.
6. On LLM error, return `{:error, reason}` — the user turn remains persisted
   (matches how a user would re-send if their network blipped); the LiveView
   shows an error and lets them retry.

## Config

Registered at boot via `Cham.Config.Manager.register("chat", schema)`:

| key                | type    | default                                    | notes                                       |
|--------------------|---------|--------------------------------------------|---------------------------------------------|
| `model`            | string  | `"llama3.1:8b"`                            | LLM model name                              |
| `url`              | string  | `"http://localhost:11434"`                 | OpenAI-compatible base URL                  |
| `api_key`          | string  | `nil`                                      | optional bearer token                       |
| `max_input_tokens` | integer | `32000`                                    | content truncation budget (chars / 4)       |
| `system_prompt`    | string  | (template below)                           | `{{content_type}}`, `{{title}}`, `{{content}}` |

Default template:

```
You are discussing a {{content_type}} titled "{{title}}".
Here is the content:

{{content}}

Answer questions about this content. Be concise and helpful.
```

This is a deliberately separate config block from `summarize_ollama` so users
can point chat at a larger / more instruction-tuned model. A future change may
unify LLM configuration; out of scope here.

## LiveView changes (`ChamWeb.ItemDetailLive`)

New assigns:

- `chat_history` — `[]` until the chat tab is opened (lazy, mirroring the
  existing transcript pattern).
- `chat_loaded?` — boolean, prevents re-reading the file on every event.
- `chat_input` — current textarea value.
- `chat_pending` — true while an LLM request is in flight.
- `chat_error` — string or nil.
- `chat_source_label` — `"article" | "transcript" | "summary" | nil`.

Events:

- `select_tab "chat"` — when first opened, calls `Cham.Chat.load_history/1`
  and `resolve_content/2`, sets `chat_loaded? = true`.
- `update_chat_input` — keep `chat_input` in sync with the textarea.
- `send_chat` — validates non-empty input; appends user turn to history
  optimistically; sets `chat_pending = true`; spawns
  `Task.async(fn -> Cham.Chat.send_message(...) end)`.
- `handle_info({ref, result}, socket)` for the task's reply — clears pending,
  replaces history with the result on success or sets `chat_error` on failure.

Disable the textarea/submit while `chat_pending`. Render an
"assistant is thinking…" placeholder bubble at the end of the visible history
during pending so the UI feels responsive.

## UI

- Match existing `--cham-*` design tokens (archivist theme already in use on
  this page).
- Header line above the messages: e.g. "Chatting against the transcript."
  (from `chat_source_label`).
- Message list: user turns right-aligned, assistant turns left-aligned,
  rendered as Markdown via `Earmark` (consistent with summary/transcript).
- Empty state when history is empty: short hint and the input.
- No-content state when `resolve_content/2` returns `{nil, nil}`: explain
  that chat is unavailable until content is processed; no input.

## Error handling

| Failure                          | Behavior                                                     |
|----------------------------------|--------------------------------------------------------------|
| LLM connection refused           | `chat_error` set; user turn stays persisted; user can retry. |
| LLM non-200                      | Same as above; surface status text in the error.             |
| File write fails on append       | `chat_error` set; do not update UI history.                  |
| JSONL line fails to decode       | Log a warning, skip the line, continue loading history.      |
| Item missing `archive_path`      | Treat as empty history; first append creates the file once `archive_path` exists. |

## Tests

Unit (`test/cham/chat_test.exs`):

- `load_history/1` returns `[]` when the file is missing.
- `load_history/1` round-trips a written history.
- `load_history/1` skips and warns on malformed lines.
- `append_turn/3` creates the file if missing and appends otherwise.
- `resolve_content/2` priority — article over summary, transcript over summary,
  summary fallback, nil when nothing is available.
- `build_system_prompt/2` substitutes all three placeholders, including when
  fields are nil (uses `"document"` and falls back to URL for missing title).

The LLM call itself is covered by the existing
`test/cham/llm/providers/openai_test.exs`; we don't add network tests here.

LiveView smoke (`test/cham_web/live/item_detail_live_test.exs`, extending the
existing test file): opening the chat tab on an item without content shows the
empty state; opening it on an item with content shows the input.

## Out of scope

- Multiple conversations per item.
- Streaming responses.
- Tool / function calling.
- Sharing transcripts of chats.
- Unifying chat config with plugin LLM configs.
