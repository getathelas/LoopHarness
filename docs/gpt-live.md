# GPT Live voice in LoopHarness

Start live chat with the waveform button **inside an empty composer** on iPhone or Mac. A floating orb shows microphone/playback activity, captions, and LoopHarness tool progress. Mute blocks microphone samples locally while keeping a silent stream running. End closes the call and restores the composer. Starting requires the user's OpenAI key in Settings → Keys and microphone permission.

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
