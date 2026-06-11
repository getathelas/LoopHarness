# Investigation: Blank Screen / Orb Shown After Tab Switch + iCloud Sync

**Date:** 2026-06-11
**Status:** Investigation complete — fix not yet implemented

## Symptoms

1. While in a conversation, switching to another iOS tab and then returning
   triggers an iCloud sync on re-entry.
2. After returning, the chat sometimes renders as a **blank screen** — as if
   it's a new chat — even though the user is still on the same conversation.
3. The **hero orb** (large empty-state avatar) is sometimes shown even though
   the conversation already has messages.

## Architecture Overview

```
SceneDelegate           — sceneDidBecomeActive / sceneWillResignActive
  ↳ no conversation reload on foreground transition

ConversationFileStore   — singleton, NDJSON-per-conversation under iCloud Documents
  ├─ in-memory cache    — [id: SimpleConversation], ordered by updatedAt
  ├─ pass-1 (bootstrap) — meta-only scan (titles + dates, NO messages)
  ├─ pass-2 (async)     — full hydration of every conversation's messages
  ├─ NSMetadataQuery    — watches messages/ folder, fires surgicalRefresh()
  └─ notifications      — .conversationStoreDidChange (debounced, on main)
                           .conversationStoreDidBecomeReady (once, after pass-1)

SimpleConversationManager
  ├─ currentConversation  — in-memory snapshot (not auto-refreshed)
  └─ loadLastConversation — reads mostRecentlyUpdatedConversation() from router

MessagingVC (subclassed by MainVC)
  ├─ self.messages        — [MessageStruct], the UI-driving array
  ├─ visible_messages     — computed filter of self.messages (hides system/function)
  ├─ loadMessagesFromConversation() — clears messages, re-reads from store
  └─ does NOT observe .conversationStoreDidChange  ← key gap

MainVC
  ├─ heroAvatar           — large orb, shown when visible_messages.isEmpty
  ├─ nav-bar avatar       — small orb, shown when visible_messages is non-empty
  └─ refreshAvatarVisibility() — single source of truth for hero ↔ nav-bar handoff
```

## Root Cause Analysis

### Bug 1 — Blank screen after returning from background (cold restart)

**Trigger:** iOS kills the app while it's in the background. User taps back in → cold start.

**Sequence:**

```
1. App launches → ConversationFileStore.init dispatches bootstrap() to ioQueue
2. MessagingVC.viewDidLoad runs on main thread
3. ConversationFileStore.shared.isReady → false (bootstrap not done yet)
4. viewDidLoad calls loadDefaultMessage()          ← blank chat displayed
   and observeConversationStoreReady()             ← one-shot observer registered
5. MainVC.viewDidLoad calls refreshAvatarVisibility(animated: false)
   visible_messages is empty → hero orb shown

── bootstrap() running on ioQueue ──

6. Pass-1 completes: meta-only cache populated (titles, dates, NO messages)
   _isReady = true → posts .conversationStoreDidBecomeReady

7. observeConversationStoreReady fires on main:
   → calls loadLastConversation()
   → mostRecentlyUpdatedConversation() returns conversation with EMPTY messages
     (pass-1 is meta-only; messages haven't been parsed yet)
   → loadMessagesFromConversation() calls getMessages()
   → ConversationFileStore.messages(forConversation:) returns [] (not hydrated)
   → messages = [systemMessage]  ← still blank

8. visible_messages.isEmpty = true → hero orb stays visible
   refreshAvatarVisibility() is NOT called from this path
   (loadLastConversation → loadMessagesFromConversation does NOT go through
    MainVC.loadConversation, which is the only override that calls refresh)

── pass-2 hydration runs on ioQueue ──

9. Full messages are parsed from disk → cache updated → .conversationStoreDidChange fires
10. SideDrawerViewController observes it → reloads sidebar list ✓
11. MessagingVC does NOT observe it → screen stays blank ✗
    Hero orb stays visible ✗
```

**Core issue:** After pass-1 signals ready, the UI loads a conversation whose
messages haven't been hydrated yet. When pass-2 finishes hydrating,
`MessagingVC` has no listener to re-read the now-populated messages.

### Bug 2 — Blank screen after returning from background (warm resume)

**Trigger:** App was suspended (not killed). User returns → `sceneDidBecomeActive`. iCloud delivers queued metadata changes via `NSMetadataQuery`.

**Sequence (less common, but possible):**

```
1. User is chatting (self.messages populated, hero hidden)
2. User switches to Safari → sceneWillResignActive
3. On another device, the same conversation is modified
4. iOS downloads the updated NDJSON file in the background
5. User returns → sceneDidBecomeActive
6. NSMetadataQuery fires .NSMetadataQueryDidUpdate
7. metadataDidUpdate → surgicalRefresh() dispatched to ioQueue

── surgicalRefresh() on ioQueue ──

8. contentsOfDirectory() enumerates messages/ folder
9. For the active conversation: file has a newer updatedAt → needsRefresh = true
10. parseFullFile() succeeds → cache[id] = parsed (with messages)
11. .conversationStoreDidChange fires on main

── Back on main ──

12. MessagingVC does NOT observe .conversationStoreDidChange
    → self.messages remains the stale in-memory copy
    → Usually fine: the user still sees their messages
```

In the warm-resume case, the user's in-memory `self.messages` is intact, so
the screen is **usually not blank**. However, there is still a
**desync risk** — the in-memory array and the store's cache can drift apart.
If anything subsequently calls `loadMessagesFromConversation()` on the
now-stale `currentConversationEntity` (e.g., the user opening the sidebar and
re-tapping the same conversation), they'd momentarily see stale data.

**Edge case — cache eviction during warm resume:**

```
surgicalRefresh() eviction logic:
  let onDiskIds = Set(urls.map { ... })
  let evictable = cachedIds.subtracting(onDiskIds).subtracting(pendingWrites)
  → removes cache entries for IDs not found on disk

If contentsOfDirectory() runs while iCloud is mid-download/rename of the
active conversation's NDJSON file, the file may not be listed → the
conversation gets evicted from cache → subsequent reads return nil/empty.
```

### Bug 3 — Hero orb shown with messages present

**Root cause:** `refreshAvatarVisibility()` is only called from these sites:

| Call site | When |
|---|---|
| `MainVC.viewDidLoad` | Once, at launch |
| `MainVC.loadConversation(_:)` | User taps a conversation in the sidebar |
| `MainVC.rightBarButtonTapped()` | User taps "new chat" |
| `MainVC.newMessageSent()` | A message is appended to the in-memory array |

**Missing call site:** When `loadLastConversation()` finishes loading messages
after the store becomes ready (step 7 above), it calls
`loadMessagesFromConversation()` — NOT `MainVC.loadConversation()`. So
`refreshAvatarVisibility()` never fires for the post-hydration path.

Even if it did fire, `visible_messages` would still be empty at that point
(because messages haven't been hydrated yet). The real fix needs to also
refresh visibility after pass-2 hydration completes.

## Specific Files & Functions Involved

| File | Key function(s) | Role |
|---|---|---|
| `LoopIOS/Data/ConversationFileStore.swift` | `bootstrap()`, `scheduleFullHydration()`, `hydrateNow()`, `surgicalRefresh()`, `metadataDidUpdate()`, `messages(forConversation:)` | iCloud sync, two-pass init, cache management |
| `LoopIOS/Data/SimpleConversationManager.swift` | `loadLastConversation()`, `getMessages(for:)` | Conversation facade, reads from cache |
| `LoopIOS/MessagingVC.swift` | `observeConversationStoreReady()`, `loadLastConversation()`, `loadMessagesFromConversation()`, `loadDefaultMessage()`, `visible_messages` | UI state, message display |
| `LoopIOS/MainVC.swift` | `refreshAvatarVisibility()`, `setupHeroAvatar()`, `loadConversation()`, `newMessageSent()` | Orb visibility handoff |
| `LoopIOS/SceneDelegate.swift` | `sceneDidBecomeActive()` | Foreground lifecycle (no conversation reload) |
| `LoopIOS/Data/ConversationStore.swift` | `ConversationStoreRouter` | Routes reads to correct backend |

## Proposed Fix Directions

### Fix A — MessagingVC observes `.conversationStoreDidChange` (primary fix)

Have `MessagingVC` subscribe to `.conversationStoreDidChange`. When it fires:

```
pseudo:
  guard let convId = currentConversationEntity?.id else { return }
  let freshMessages = conversationManager.getMessages(for: convId)
  if freshMessages != currentMessageSnapshot:
      reloadMessagesFromStore(convId)
      refreshAvatarVisibility()
```

**Guard against churn:** The notification is debounced (100 ms) but can fire
often during pass-2 hydration of unrelated conversations. The handler should
check whether the *current* conversation's data actually changed (compare
message count or the last message's id/createdAt) before touching the table.

**Guard against clobbering in-flight state:** If the agent is mid-response
(`ai_state != .None` or `streamingPartial` is non-empty), skip the reload —
the live turn's data lives in memory and hasn't been flushed to disk yet,
so a store-based reload would drop the partial response.

### Fix B — Re-hydrate the current conversation on foreground (complementary)

In `sceneDidBecomeActive` (or via a notification that `MessagingVC` observes):

```
pseudo:
  guard let convId = currentConversationEntity?.id else { return }
  store.hydrateAsync(id: convId)  // triggers pass-2 for just this one
  // When done, .conversationStoreDidChange fires → Fix A picks it up
```

This ensures the *active* conversation is prioritized for hydration rather than
waiting behind 50 other conversations in the pass-2 queue.

### Fix C — `loadLastConversation` waits for hydration (targeted)

Instead of loading the conversation immediately when `.conversationStoreDidBecomeReady`
fires (when messages are still empty), defer the load until the conversation is
hydrated:

```
pseudo:
  // In observeConversationStoreReady callback:
  let conv = conversationManager.loadLastConversation()
  if conv.messages.isEmpty && !store.hydratedIds.contains(conv.id):
      // Don't render yet — wait for hydration
      store.hydrateAsync(id: conv.id)
      // When .conversationStoreDidChange fires (Fix A), render then
  else:
      loadMessagesFromConversation(conv)
```

### Fix D — `refreshAvatarVisibility` on `loadMessagesFromConversation` (quick win)

At the end of `loadMessagesFromConversation`, call a hook that `MainVC` overrides:

```swift
// MessagingVC:
func messagesDidReload() { }

// MainVC:
override func messagesDidReload() {
    refreshAvatarVisibility()
}
```

This ensures the hero orb collapses whenever messages are loaded from any path —
not just `loadConversation` and `newMessageSent`.

## Quick Wins / Guardrails

1. **Prioritize active conversation in pass-2 hydration.**
   `scheduleFullHydration()` iterates `orderedIds` (by updatedAt). But the
   conversation the user is *looking at* should be hydrated first. Move it to
   the front of the queue — or hydrate it synchronously as part of
   `observeConversationStoreReady` before handing off to the UI.

2. **Defensive empty-state guard in `loadMessagesFromConversation`.**
   If `getMessages()` returns empty but the conversation's `updatedAt` suggests
   it should have content, show a loading spinner instead of a blank screen.

3. **Add `contentsOfDirectory` tolerance in `surgicalRefresh`.**
   If `contentsOfDirectory` misses a file that was in the cache, don't evict
   it on the first pass. Use a "marked for eviction" set and only evict if the
   file is still missing on the *next* refresh. This prevents transient iCloud
   download/rename operations from evicting an active conversation.

4. **Log the hydration race.** Add a `print` or `AppSignals.emit` when
   `messages(forConversation:)` returns `[]` for a conversation that exists
   in cache but isn't hydrated — this makes the race visible in console logs
   for future debugging.

## Recommendation

Implement **Fix A + Fix D** as the minimum viable fix. Fix A closes the
notification gap so the UI self-heals after any store change. Fix D ensures
the orb state is correct on every message-load path. Both are small,
low-risk changes.

Consider **Fix B** (foreground re-hydration) as a polish pass — it makes the
recovery instant on warm resume rather than waiting for the metadata query to
fire. **Fix C** and the quick wins can be layered on for robustness.
