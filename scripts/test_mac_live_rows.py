#!/usr/bin/env python3
"""Exercise the production AppKit Live-row updater without network or user storage."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "LoopMac/ConversationWindowController.swift").read_text()
start = source.index("    private func renderLiveRows(")
end = source.index("    private func makeLiveRow(", start)
method = source[start:end].replace("private func renderLiveRows", "func renderLiveRows", 1)
prefix = r'''import AppKit
import SwiftUI
struct PDF { var status = "ready"; var fileURL: URL? }
struct MessageStruct {
 var id: String; var role = "assistant"; var content: String
 var liveActivity: String?; var pdfAttachment: PDF?; var fileAttachment: String?
 var model = "GPT Live 1"
}
struct Conversation { var id = "origin" }
struct Tab { var conversation = Conversation() }
final class LiveSession { static let shared = LiveSession(); var conversationID: String? = "origin" }
struct MacLiveActivityRow: View { let activity: String; let model: String; var body: some View { Text(activity) } }
final class Flipped: NSView { override var isFlipped: Bool { true } }
final class Harness {
 let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
 let stack = NSStackView()
 var activeTab: Tab? = Tab()
 var liveRowViews: [String: NSView] = [:]
 var liveRowSnapshots: [String: MessageStruct] = [:]
 var follows = 0
 init() {
  let document = Flipped(frame: NSRect(x: 0, y: 0, width: 500, height: 2000))
  scrollView.documentView = document
  stack.frame = document.bounds
  stack.orientation = .vertical
  document.addSubview(stack)
 }
 func makeLiveRow(_ row: MessageStruct) -> NSView {
  NSTextField(labelWithString: row.content)
 }
 func scrollToBottom() { follows += 1 }
'''
suffix = r'''
}
let h = Harness()
let history = NSTextField(labelWithString: "Earlier conversation")
history.heightAnchor.constraint(equalToConstant: 2000).isActive = true
h.stack.addArrangedSubview(history)
h.scrollView.documentView?.layoutSubtreeIfNeeded()
h.scrollView.contentView.scroll(to: .zero)
let first = MessageStruct(id: "one", content: "Hello")
h.renderLiveRows([first])
let firstView = h.liveRowViews["one"]!
assert(h.stack.arrangedSubviews.first === history, "History must retain its view")
h.renderLiveRows([first, MessageStruct(id: "two", content: "Hi")])
assert(h.liveRowViews["one"] === firstView, "Unchanged rows must retain their view")
assert(h.stack.arrangedSubviews.count == 3)
h.renderLiveRows([MessageStruct(id: "one", content: "Hello again"), MessageStruct(id: "two", content: "Hi")])
assert(h.stack.arrangedSubviews.count == 3, "Deltas must replace rather than duplicate a row")
assert((h.liveRowViews["one"] as? NSTextField)?.stringValue == "Hello again")
assert(h.stack.arrangedSubviews.first === history)
assert(h.follows == 0, "Reading history must not auto-follow")
let count = h.stack.arrangedSubviews.count
h.activeTab?.conversation.id = "elsewhere"
h.renderLiveRows([MessageStruct(id: "other", content: "Wrong conversation")])
assert(h.stack.arrangedSubviews.count == count, "A different conversation must remain untouched")
h.activeTab?.conversation.id = "origin"
h.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1750))
h.renderLiveRows([first])
assert(h.follows == 1, "Readers at the bottom should follow speech")
assert(h.liveRowViews["two"] == nil)
print("PASS: retained history and unchanged rows, delta replacement, scroll following, conversation isolation, stale-row removal")
'''
with tempfile.TemporaryDirectory(prefix="mac-live-rows-") as directory:
    swift = Path(directory) / "main.swift"
    swift.write_text(prefix + method + suffix)
    binary = Path(directory) / "test"
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(binary)], env=env, check=True)
    subprocess.run([str(binary)], env=env, check=True)
