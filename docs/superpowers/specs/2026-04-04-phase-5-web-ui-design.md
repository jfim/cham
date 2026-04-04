# Phase 5: Web UI — Design Spec

## Goal

Build a LiveView-based web interface for browsing, submitting, and monitoring items in the Cham knowledge archive. Text-based content display only — media playback, search, chat, and pagination are deferred.

## Architecture

Two independent LiveViews connected by standard navigation:

- `DashboardLive` (`GET /`) — sidebar + item list, the main browse/filter/submit experience
- `ItemDetailLive` (`GET /items/:id`) — full-width item detail with processing status

Both use the `:app` layout with a minimal header (just "Cham" branding, replacing the default Phoenix header). The sidebar is part of `DashboardLive`'s template, not a shared layout component. Item detail is full-width with no sidebar.

Filter state (content type, tag) is encoded in URL query params (`?type=video&tag=foo`) via `push_patch`, so the browser back button preserves filter context.

## Pages

### Dashboard

Two-panel layout: fixed left sidebar + scrollable main content area.

#### Sidebar

Implemented as a function component within `DashboardLive`'s template. All state lives in LiveView assigns.

Sections (top to bottom):

1. **Logo** — "Cham" text at top.
2. **Add URL button** — primary action, opens submit modal.
3. **In Progress** — collapsible disclosure, collapsed by default. Count badge shows number of items in `bootstrapping` or `processing` status. Expanding reveals a list of active items, each showing:
   - Stage badge with human-friendly label and color coding (e.g. "downloading", "transcribing")
   - Truncated title (or URL if no title)
   - Clicking navigates to item detail
   - Failed items appear at bottom with red "failed" badge, incomplete items with yellow "incomplete" badge
   - Count badge reflects only `bootstrapping`/`processing` items. If only failed/incomplete remain, show warning indicator instead.
   - Real-time updates via EventBus subscription.
4. **Content type facets** — list of types with item counts (Articles, Videos, Docs, Podcasts). Click to filter main content, click active type to deselect. Counts reflect current DB state.
5. **Tags** — wrapped pill layout with counts. Single-select: clicking a tag filters items, clicking active tag deselects.

#### Main Content Area

- **Hero text** — "Cham knows about **N** pieces of information". Adapts when filtered: "**N** videos", "**N** items tagged machine-learning", etc.
- **Search box** — placeholder, non-functional (deferred). Text adapts to filter context.
- **Item list** — all items loaded (no pagination), ordered by `inserted_at DESC`. Display varies by content type filter:
  - **No filter / Articles / Podcasts:** List rows — content type badge, title (or truncated URL), source domain, relative date.
  - **Videos:** Card grid (3 columns) — placeholder thumbnail area, title, source domain, relative date.
  - **Documents:** Card grid (3 columns) — placeholder page icon, title, relative date.
- **Empty states** — contextual messages:
  - Empty archive: "Submit your first URL to get started"
  - No items matching filter: "No [type] in your archive yet"

### Item Detail

Full-width, no sidebar. Content-type-adaptive layout.

#### Top Bar

- Back link: "Back to archive" (or "Back to videos" etc. if navigated from a filtered view — return filter encoded in query param `?return_type=video`)
- Tag pills displayed inline, read-only

#### Primary Content (varies by type)

- **Article:** Title, source domain + external link, stats (date), article text rendered from the `origin:original, format:text` artifact.
- **Video:** Placeholder area ("Video playback coming soon" with link to original URL), title, source, date. Transcript text below if available.
- **Document:** Placeholder area ("PDF viewer coming soon" with link to original URL), title, date.
- **Generic/Unknown:** Title or URL, source, date, list of available artifacts.

#### Content Availability States

Each content section (article text, summary, transcript, etc.) shows one of four states, determined by cross-referencing artifacts and stage execution history:

1. **Available** — artifact exists with status `"produced"` → render the content
2. **Processing** — a stage that would produce this artifact has status `"started"` in stage_executions → "Currently being generated..." with spinner
3. **Failed** — stage exists with status `"failed"` → "Generation failed: [error message]"
4. **Not requested** — no artifact and no stage execution exists → "Not available for this item"

#### Collapsible Bottom Pane

Default: collapsed, only tab bar visible. Clicking a tab expands the pane.

Tabs shown based on content type:
- **Summary** — rendered from `origin:derived, type:summary` artifact text. Shows appropriate availability state if not yet available.
- **Transcript** — (videos/audio only) rendered from transcript artifact.
- **Metadata** — raw item metadata as formatted JSON.
- **Chat** — empty placeholder ("Coming soon").
- **Actions** — empty placeholder ("Coming soon").

#### Processing View

When item status is `bootstrapping` or `processing`, additional processing information is shown:

- Status badge prominently displayed
- Stage execution timeline from `Tracker.get_stage_history(item.id)` — each stage with status icon, name, duration
- Real-time progress bars for active stages
- Content appears progressively as artifacts are produced

### Submit Modal

- Triggered by "Add URL" button in sidebar
- Uses `CoreComponents.modal`
- Single URL text input + submit button
- On submit: calls `Pipeline.submit_url/2`
- **Success:** closes modal, flash message. New item appears in "In Progress" via real-time EventBus update.
- **Error:** inline error below input (e.g. "URL already exists", "Invalid URL")
- Duplicate URL is rejected (re-archiving deferred for future design)

## Real-Time Updates

### Dashboard

- `mount/3` subscribes to `"item"` topic via `EventBus.subscribe("item")`
- Pattern: subscribe first, then load initial state from DB (avoids missing events between read and subscribe)
- `handle_info` receives item creation/status change events
- Updates "In Progress" list, count badge, and main item list in assigns

### Item Detail

- `mount/3` subscribes to `"pipeline"` topic
- `handle_info` matches on `StageStarted`, `StageCompleted`, `StageFailed`, `StageProgress` where `item_id` matches the current item
- Updates stage timeline, progress bars, and artifact availability
- When a new artifact is produced, the corresponding content section updates

### Non-Disruptive Update Principle

Real-time updates must be additive, never disruptive to the user's current activity:

- **Primary content area:** Never re-render or replace content the user is actively viewing. Use targeted `assign` updates, not full-page re-renders.
- **Bottom pane tabs:** Update content silently. If user is on a tab showing "Currently being generated...", transition to content. If on a different tab, content is ready when they click over.
- **Stage timeline / progress bars:** Update freely (informational, expected to change).
- **Status badge:** Update freely (small, non-disruptive).
- **Future media containers:** Use `phx-update="ignore"` to prevent LiveView from re-rendering active media players.

## Visual Design

- Clean, modern aesthetic with good whitespace
- Color-coded content type badges: blue (Article), pink (Video), green (Doc), purple (Podcast)
- Color-coded stage badges: blue (downloading), purple (transcribing), amber (summarizing)
- Subtle borders, rounded corners
- System font stack
- Sidebar: white background, light gray borders
- Main area: off-white background
- Accent color: indigo/blue

## Data Access

### Queries Needed

- `Items.list_items(filters)` — filter by content_type, tag, ordered by `inserted_at DESC`
- `Items.list_items(status: [...])` — for in-progress sidebar section
- `Items.count_by_content_type()` — for sidebar facet counts
- `Items.count_by_tag()` — for sidebar tag counts
- `Items.get_item!(id)` with preloaded artifacts
- `Items.list_artifacts(item_id)` — for item detail content resolution
- `Tracker.get_stage_history(item_id)` — for processing timeline

Some of these query functions may need to be added to the `Items` context.

### Artifact Resolution

The UI resolves content by querying artifacts by label, not by hardcoded file paths:

- Article text: artifact with `origin:original, format:text`
- Summary: artifact with `origin:derived, type:summary`
- Transcript: artifact with `origin:derived, type:transcript`

File content is read from the archive filesystem using the artifact's `path` field to locate the directory and `filenames` to find the file.

## Dependencies

- `Cham.Items` — item/artifact CRUD and queries
- `Cham.EventBus` — real-time PubSub
- `Cham.JobTracking.Tracker` — stage history and ephemeral progress
- `Cham.Pipeline` — `submit_url/2` for the submit modal
- `Cham.Archive.MetadataManager` — reading artifact file content
- `CoreComponents` — modal, flash, form components (already exist)

## Deferred from Phase 5

See `docs/deferred-implementation-items.md` for details:
- Chat tab functionality
- Search
- Archive file serving endpoint
- Media viewers (video, PDF, images)
- Pagination
- Re-archiving existing URLs
