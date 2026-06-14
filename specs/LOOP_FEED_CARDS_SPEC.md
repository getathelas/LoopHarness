# Loop Feed + Cards — v1 Spec

## Overview

A new **Feed tab** in the side drawer surfaces AI-generated visual "cards" the
user can swipe through, keep, or archive. Cards are produced by a new
`generate_card` tool the agent calls during conversation.

## 1. New Tool: `generate_card`

Registered like other Loop tools. Inputs:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `kind` | `"image"` \| `"markdown"` | yes | Determines renderer |
| `title` | string | yes | Short (≤6 words) |
| `body` | string | yes | Content/subtitle |
| `image_prompt` | string | when kind=image | Vivid image generation prompt |
| `source` | string | no | Attribution |
| `tags` | string[] | no | Lowercase keywords |

Output: a persisted Card (JSON at `workspace://cards/<id>.json`).

## 2. Card Schema

```json
{
  "id": "uuid",
  "kind": "image|markdown",
  "title": "...",
  "body": "...",
  "image_url": "cards/assets/<id>.png",
  "source": "calendar",
  "tags": ["morning", "routine"],
  "created_at": "2026-06-14T05:00:00.000Z",
  "state": "new|kept|archived"
}
```

Image assets: `workspace://cards/assets/<id>.png`

## 3. Pluggable Renderer Interface

`CardRendering` protocol with `render(card:completion:)`.

- **v1 `image` renderer**: pipes `image_prompt` through OpenAI image generation
  at 4:3 landscape (1536×1024).
- **v1 `markdown` renderer**: renders title + body to a 4:3 poster PNG via
  UIKit offscreen render. Dark background, clean typography, Loop-branded.

Future backends (HTML→image, Higgsfield, vectors) conform and register without
changing the tool surface.

## 4. Feed Tab UX

- New "Feed" tab in the side drawer (first position, default on open).
- Empty state: "Tap the orb or type to start a conversation".
- Cards displayed as rows (title, kind badge, state indicator).
- Tap → detail view with full poster, title, body, metadata, action buttons.
- Swipe right → **Keep** (persists across sessions).
- Swipe left → **Archive** (hidden but recoverable).
- `new` cards sort to top; `kept` persist below; `archived` hidden.

## 5. Pill Alert

When `generate_card` completes, a lightweight toast/pill appears in the current
conversation: "✨ new card". Tapping navigates to the Feed tab. Auto-dismisses
after 4 seconds.

## 6. Out of Scope (v1)

- External sharing/export
- Multi-page/scrolling cards
- Heartbeat-driven proactive card generation

## Key Results

- (A) New tab opens to Feed, not blank input.
- (B) "Generate a card on my day tomorrow" → markdown card from calendar.
- (C) "Generate a card of teaching Leo loose-leash walking" → image card.
- (D) Swipe to Keep/Archive; kept cards persist + sync via workspace.
- (E) `renderCard` cleanly factored for future kinds.
