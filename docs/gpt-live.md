# GPT Live voice in LoopHarness

Start live chat with the waveform button **inside an empty composer** on iPhone or Mac. On iPhone, the live orb replaces the navigation avatar, a blue screen outline responds to spoken output, and compact mute/end controls replace the composer. Speech and tool activity appear progressively in the conversation; ending the call saves the same stable rows without duplication. Updates are throttled and preserve the scroll position while reading older messages. Mac retains its floating orb. Reduce Motion disables the animated sweep and orb movement. Mute blocks microphone samples locally while keeping a silent stream running. End closes the call and restores the composer. Starting requires the user's OpenAI key in Settings → Keys and microphone permission.

GPT Live 1 handles voice. Client delegation calls the existing `Cloud` → `AgentHarness` path using the selected thinking model, harness documents, tool schemas, and `SkillDispatcher` (including its duplicate-call guard and existing permission/confirmation behavior). The live model cannot execute tools directly. This follows OpenAI's [client delegation guide](https://developers.openai.com/api/docs/guides/live-delegation).

The native client uses the user's Keychain-managed API key, consistent with existing direct provider integrations. No application-owned project key is shipped. A managed-key deployment should introduce a trusted broker and WebRTC as described in the [connection guide](https://developers.openai.com/api/docs/guides/voice-webrtc). The current transport uses the documented [Live WebSocket contract](https://developers.openai.com/api/docs/guides/voice-websockets), mono PCM16 at 24 kHz, resampling, and AVAudioEngine voice processing for echo cancellation. It does not use Realtime's commit/response voice-turn loop.

## Lifecycle and records

- Audio begins only after `session.started`; capture and playback remain independent.
- Input/output transcript fragments retain timestamps in session memory. Only delegation events trigger thinking; incomplete transcript fragments never independently trigger tools.
- Delegations are deduplicated and serialized. User corrections received during inference cause tool proposals to be reconsidered. Tools within a batch execute sequentially.
- Closing stops microphone/playback immediately, invalidates queued agent continuations, and requests `session.close`, waiting at most 15 seconds for finalization. It cannot undo an already-dispatched external operation. Its eventual result updates the original conversation's task record without speaking or starting further work.
- Active calls continue when switching apps or locking the iPhone using the existing audio background mode. The orb and End control remain available when returning to Loop. Live tasks stay in the local call instead of being handed off to a background runner. Conversation switches, iOS audio interruptions/input-device loss, and macOS audio-engine loss end the session. Connection and queue failures require explicit retry; there is no automatic retry of uncertain tool actions.
- Spoken transcript groupings and separate backend task records are saved to the originating conversation. API audio storage is disabled (`store: false`). No raw microphone recording is written by this feature.
- Backend requests have a two-minute watchdog and a twelve-round limit. Audio send and playback queues are bounded.

## Validation

Run the protocol checks without Xcode test-target configuration:

```sh
xcrun swiftc LoopIOS/Live/LiveProtocol.swift scripts/test_live_protocol.swift -o /tmp/test-live
/tmp/test-live
```

A local Mac audio smoke test is also available (requires existing microphone permission and discards all captured samples):

```sh
xcrun swiftc LoopIOS/Live/LiveAudio.swift LoopMac/MicrophoneManager.swift scripts/test_live_audio.swift -o /tmp/test-live-audio
/tmp/test-live-audio
```

The Mac voice-processing engine requires identical client-side capture/playback formats. Both I/O clients explicitly use mono at the hardware sample rate: accepting the aggregate channel layout caused all-zero capture on the development Mac, while mono negotiation produced a nonzero microphone signal. The player produces 24 kHz audio; the main mixer explicitly converts to the microphone format before feeding the output node. Removing that connection reproduced Core Audio `-10875`; restoring it passed microphone capture and silent playback initialization on the development Mac.

Build `Loop_MacOS` and `Loop_iOS` with Xcode. Hardware testing must use a development-signed build with the project entitlements: an unsigned Mac build cannot read the shared data-protection Keychain, so Live may connect using a development OpenAI key while the selected thinking provider has no accessible credential. Live now reports the missing provider key explicitly. The duplicate-tool guard resets for each new delegated request and remains active throughout its tool loop. Before release, test with an OpenAI key that has GPT Live access on actual iPhone and Mac audio hardware:

1. Empty composer shows Start live chat; typed text/attachments hide it.
2. Missing key and denied microphone show an actionable error; End restores input.
3. Talk, pause, and interrupt on speaker and Bluetooth/headset routes. Verify echo cancellation, understandable audio, independent captions, and mute.
4. Ask a read-only tool question; check the selected model, tool result, spoken answer, and saved conversation.
5. End or switch chats during thinking/tool execution. Confirm no late speech, no subsequent tool dispatch, and the result stays with the original conversation.
6. Switch to another app and lock the iPhone during a connected call. Verify spoken replies and a read-only tool request continue, then return and use End to stop capture. Separately disconnect the network, unplug the microphone, or trigger an audio interruption; confirm the call stops and retry starts a fresh session.

Builds and local protocol tests do not verify account/model access, live latency, audio-route behavior, or successful spoken tool use.

### Live conversation regression checks

The test concatenates an extension after the real session implementation to exercise private event handling with local fake audio, storage, model, and tool dependencies. No network requests or microphone capture are performed.

```sh
cat LoopIOS/Live/LiveSession.swift scripts/test_live_session.swift > /tmp/live-session-tests.swift
xcrun swiftc LoopIOS/Live/LiveProtocol.swift /tmp/live-session-tests.swift -o /tmp/live-session-tests
/tmp/live-session-tests
```

Checks progressive transcript grouping, stable row IDs, immediate tool activity, replacement with completed results, and exactly-once final persistence. The light/dark native component renders were inspected; full device interaction still needs a spoken-call check.

The iPhone speaking border is a child of the window root controller and is attached inside that controller’s view. A device crash report identified `UIViewControllerHierarchyInconsistency` when the old chat child was attached directly to UIWindow. A native simulator reproduction crashed with the old hierarchy and passed three attach/layout/detach cycles with the corrected hierarchy.

The compact navigation orb belongs to UINavigationController, which owns the navigation bar containing its view. Live console capture identified a second hierarchy exception here; the expanded native reproduction covers both the header orb and screen border and passes repeated open/close cycles after both fixes.

## Voice and reasoning history

GPT Live speech is labelled **Voice · GPT Live 1** in blue. Each delegated request has one amber **Reasoning & tools** card attributed to the selected model, without the provider transport suffix. Tools appear when dispatched, with their input JSON, full output (including source URLs), call ID, state, start/end times and duration retained in the conversation. The details are expandable. Successful/read-only cards collapse after subsequent spoken output; actions, failures, and requests for input stay visible. Returned output is distinguished from explicit success. Ending a call marks unfinished requests rather than presenting them as completed; late tool results update the original record.

Activity metadata and model attribution are encoded in the actual NDJSON message envelope. Older messages still decode without activity metadata. Tests cover activity serialization, error visibility, stable live rows, and no duplicate final persistence; an additional storage test exercised the actual SimpleMessage and MessageLineEnvelope encoder/decoder.

### Images in Live cards

Image-search results appear as thumbnails in their reasoning and tools card, with links to the source pages. Tap a thumbnail to enlarge it. Generated images show a loading placeholder, then update the same card with the image or a failure message. Images remain visible when tool details collapse and are saved with the conversation. Generation that finishes after ending a call updates its original conversation; ordinary text-chat image delivery is unchanged.

In Live mode, tap the reasoning card area to expand/collapse it, or tap a tool's area to toggle its inputs and result. Explicit expansion is retained across updates. While a card is manually open, incoming results and images continue updating. Automatic following is disabled and the visible message is anchored so updates above it do not jump the screen. Closing the card does not jump to the bottom. Expansion transitions do not animate.

Existing workspace images shared through `share_file` also appear in Live cards. The attachment is resolved against the current workspace before display; a textual success message alone is not treated as image data. Live instructions require a new share call when the user asks to display an existing image, rather than repeating an earlier tool log.

Live speech deltas reconfigure only changed rows while message IDs are stable, so unrelated image cards are not recreated on every transcript update. Image resources share a bounded cache of decoded images and in-flight loads, independent of table-cell lifetime. A native regression check verified that 100 repeated image-view resource lookups reuse the loaded bitmap even after its source fixture is removed.

## Live PDF generation

iOS `generate_pdf` results are owned by the originating Live request. Placeholders and completed PDFs stay in the Live row stream, so normal chat host creation cannot switch the conversation and stop the call. Completed PDFs carry a persistent file attachment and remain previewable after the call. Late render callbacks update the original conversation without entering a subsequent call; failed renders can be retried.

The two-minute delegated-work timer reports that the task is still running and retains the original request. It does not close the audio session or replay an uncertain tool action. The session regression harness covers slow-work completion, PDF success/failure/retry, late persistence, and same-conversation restart isolation.

## Music during Live

Live uses a mixable iOS play-and-record audio session and voice-processing advanced ducking at the medium level. Music remains playing while speech temporarily lowers its volume. The legacy voice loop's automatic pause/resume logic does not take over an active Live call; explicit music pause/stop still works. Ending Live releases microphone use without deactivating a playing ApplicationMusicPlayer.

Native offline regression (Apple Silicon Mac, already-booted iOS simulator):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/test_live_music_ios.py SIMULATOR_UDID
```

This test plays a quiet generated tone with AVAudioPlayer alongside the real LiveAudio engine, checks capture continues, and pauses/resumes the tone. Microphone samples are discarded. It validates local audio coexistence, not Apple Music subscription playback or a real GPT Live conversation. Hardware check: start Live, request music, ask a follow-up over the music, pause/resume music, and end Live while music is playing. Confirm the call stays connected, speech is audible, explicit playback controls work, and music continues after End.

## Mac conversation integration

On macOS, Start live chat opens the conversation window and places mute, status,
retry, and End controls beneath the chat. Speech updates appear as user and
assistant messages alongside earlier history. Unchanged rows retain their views;
a reader scrolled into history is not automatically pulled to the newest speech.
Reasoning cards use the shared disclosure UI. Ending a call preserves its rows,
and a store reload reconciles them by ID to avoid duplicate messages. Switching
conversations ends the originating call through the shared session lifecycle.

Run the native Mac rendering regression without network or user storage:

```sh
python3 scripts/test_mac_live_rows.py
```

This extracts the production row updater into an AppKit fixture and checks history
retention, delta replacement, unchanged-row identity, scroll-follow decisions,
conversation isolation, and removal of stale rows. The session regression above
covers stable transcript IDs and final persistence.
