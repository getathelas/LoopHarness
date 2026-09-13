import Foundation
import Combine
import AVFoundation

struct FunctionCallStruct { var name: String; var arguments: [String: Any] = [:]; var callId: String?; var conversationId: String? }
struct MessageStruct {
 var liveActivity: LiveActivityRecord? = nil
 var id = UUID().uuidString
 var role: String; var content: String; var model: String = "Test"; var name: String? = nil; var callId: String? = nil
 var functions: [FunctionCallStruct] = []
}
struct SimpleConversation { var id = "test-only" }
extension Notification.Name { static let activeConversationDidChange = Notification.Name("testConversationChange") }
final class SimpleConversationManager {
 static let shared = SimpleConversationManager(); var saved: [MessageStruct] = []; var currentConversation: SimpleConversation? = SimpleConversation()
 func createConversation(title: String) -> SimpleConversation { SimpleConversation() }
 func getMessages(for: SimpleConversation) -> [MessageStruct] { [] }
 func messageStruct(from value: MessageStruct) -> MessageStruct { value }
 func addMessage(_ m: MessageStruct, to: SimpleConversation) { saved.append(m) }
 func updateMessage(_ m: MessageStruct, in: SimpleConversation) {}
}
final class KeyStore {
 enum Key { case openAI; var displayName: String { "Test" } }; static let shared = KeyStore()
 func value(for key: Key) -> String? { "test-only-key" }
}
enum ModelSelectionStore { struct Model { let stampedMessageModel = "Test"; var requiredKey: KeyStore.Key? { nil } }; static let current = Model() }
final class AgentActivityLog {
 enum Kind { case toolCall, toolResult, status }; static let shared = AgentActivityLog()
 func log(_ kind: Kind, _ name: String) {}
}
final class Cloud {
 static let connection = Cloud(); var requests = 0
 func chat(messages: [MessageStruct], completion: @escaping (MessageStruct?, Error?) -> Void) {
  requests += 1
  completion(MessageStruct(role:"assistant",content:"Hello, I can hear you."), nil)
 }
}
final class SkillDispatcher {
 static let shared = SkillDispatcher()
 func dispatch(_ c: FunctionCallStruct, completion: @escaping (MessageStruct) -> Void) { completion(MessageStruct(role:"function",content:"test result")) }
}

final class ToolCallGuard {
 static let shared = ToolCallGuard()
 func resetForNewTurn() {}
}
final class LiveAudio {
 var onInput: ((Data, Float) -> Void)?
 var onOutputLevel: ((Float) -> Void)?
 var isRunning = true
 func start() throws {}
 func play(_ data: Data) throws {}
 func stop() {}
}

// Concatenate this test after LiveSession.swift so the extension can exercise
// its private event handler without changing the production access controls.
extension LiveSession {
 func testLiveRows() throws {
  conversation = SimpleConversation(); state = .connected
  func transcript(_ role: String, _ text: String) throws {
   try receive(["type": role == "user" ? "session.input_transcript.delta" : "session.output_transcript.delta", "delta": text], token: generation)
  }
  try transcript("user", "Hello")
  let firstID = liveMessages[0].id
  try transcript("user", " there")
  precondition(liveMessages.count == 1 && liveMessages[0].content == "Hello there" && liveMessages[0].id == firstID)
  try transcript("assistant", "Checking now.")
  let work = UUID(); workID = work
  var card = MessageStruct(id: work.uuidString, role: "assistant", content: "Working")
  card.liveActivity = LiveActivityRecord()
  liveMessages.append(card)
  execute([FunctionCallStruct(name: "test_lookup", callId: "call_1")], index: 0,
          delegation: "opaque", work: work, remaining: 2, transcriptCount: fragments.count)
  precondition(liveMessages.count == 3 && liveMessages.last!.liveActivity?.tools.count == 1)
  let toolID = liveMessages.last!.id
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  precondition(liveMessages.contains { $0.id == toolID && $0.liveActivity?.tools.first?.output == "test result" })
  try transcript("assistant", "Here is your answer.")
  precondition(liveMessages.first { $0.id == toolID }?.liveActivity?.spoken == true)
  let activity = liveMessages.first { $0.id == toolID }!.liveActivity!
  let restored = try JSONDecoder().decode(LiveActivityRecord.self, from: JSONEncoder().encode(activity))
  precondition(restored.tools.first?.output == "test result")
  var failure = LiveToolRecord(id: "failed", name: "get_test", input: "{}", needsAttention: false)
  failure.finish("{\"status\":\"error\",\"error\":\"Unavailable\"}")
  precondition(failure.state == "failed" && failure.needsAttention)
  let ids = liveMessages.map(\.id)
  persistTranscript(); persistTranscript()
  precondition(SimpleConversationManager.shared.saved.map(\.id) == ids)
  precondition(Set(ids).count == ids.count)
  precondition(liveMessages.map(\.id) == ids)
  print("PASS: progressive speech, stable row IDs, immediate tool activity, in-place results, persistence without duplication")
 }
}
@main struct Tests {
 static func main() throws { try LiveSession.shared.testLiveRows() }
}
