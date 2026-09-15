import Foundation
import Combine
import AVFoundation

struct FunctionCallStruct { var name: String; var arguments: [String: Any] = [:]; var liveRequestID: String? = nil; var callId: String?; var conversationId: String? }
struct MessageStruct {
 var fileAttachment: FileAttachment? = nil
 var imageGalleryAttachment: ImageGalleryAttachment? = nil
 var liveActivity: LiveActivityRecord? = nil
 var id = UUID().uuidString
 var role: String; var content: String; var model: String = "Test"; var name: String? = nil; var callId: String? = nil
 var functions: [FunctionCallStruct] = []
 var pdfAttachment: PDFAttachment? = nil
}
struct SimpleConversation { var id = "test-only" }
extension Notification.Name { static let activeConversationDidChange = Notification.Name("testConversationChange") }
final class SimpleConversationManager {
 static let shared = SimpleConversationManager(); var saved: [MessageStruct] = []; var currentConversation: SimpleConversation? = SimpleConversation()
 func createConversation(title: String) -> SimpleConversation { SimpleConversation() }
 func getMessages(for: SimpleConversation) -> [MessageStruct] { saved }
 func messageStruct(from value: MessageStruct) -> MessageStruct { value }
 func addMessage(_ m: MessageStruct, to: SimpleConversation) { saved.append(m) }
 func updateMessage(_ m: MessageStruct, in: SimpleConversation) { if let index = saved.firstIndex(where: { $0.id == m.id }) { saved[index] = m } }
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
 var file: FileAttachment?
 var gallery: ImageGalleryAttachment?
 func dispatch(_ c: FunctionCallStruct, completion: @escaping (MessageStruct) -> Void) { completion(MessageStruct(fileAttachment: file, imageGalleryAttachment: gallery, role:"function",content:"test result")) }
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
 static func main() throws {
  try LiveSession.shared.testLiveRows()
  LiveSession.testImageRouting()
  try LiveSession.testGalleryRouting()
  LiveSession.testPDFRouting()
  LiveSession.testSlowWork()
 }
}

struct ImageAttachment: Codable {
    enum Status: String, Codable, Equatable {
        case generating
        case ready
        case failed
    }

    let id: String
    let prompt: String
    var fileURL: URL?
    var status: Status
    var failureReason: String?
    /// Conversation the generation belongs to. Captured at submit time so the
    /// host can route the bubble to the right tab on multi-tab Mac, even if
    /// the user switches tabs between "tool call fired" and "image ready".
    /// Optional for backward compatibility with callers (iOS / older paths)
    /// that don't supply it — those clients render whatever conversation is
    /// currently visible, which is the right behavior for single-tab UIs.
    let conversationId: String?

    init(id: String = UUID().uuidString,
         prompt: String,
         fileURL: URL? = nil,
         status: Status = .generating,
         failureReason: String? = nil,
         conversationId: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.fileURL = fileURL
        self.status = status
        self.failureReason = failureReason
        self.conversationId = conversationId
    }
}
struct ImageGalleryAttachment: Codable, Equatable {
    struct Item: Codable, Equatable {
        /// Small image URL used for the thumbnail grid.
        let thumbnailURL: String
        /// Full-resolution image URL opened on tap.
        let originalURL: String
        /// Source page the image was found on (for attribution / "view source").
        let sourceLink: String?
        /// Short image title from the search result.
        let title: String?
    }

    let id: String
    /// The search query that produced these results (shown as a caption).
    let query: String
    let items: [Item]
    var conversationId: String?

    init(id: String = UUID().uuidString,
         query: String,
         items: [Item],
         conversationId: String? = nil) {
        self.id = id
        self.query = query
        self.items = items
        self.conversationId = conversationId
    }
}

extension LiveSession {
 static func testImageRouting() { LiveSession().testImageUpdates() }
 func testImageUpdates() {
  SimpleConversationManager.shared.saved = []
  conversation = SimpleConversation(); state = .connected
  let request = UUID().uuidString
  var row = MessageStruct(id: request, role: "assistant", content: "Image request")
  row.liveActivity = LiveActivityRecord(tools: [LiveToolRecord(id: "image-tool", name: "generate_image", input: "{}")])
  liveMessages = [row]
  let pending = ImageAttachment(id: "image-1", prompt: "Test illustration", status: .generating)
  registerLiveImage(pending, requestID: request)
  precondition(receiveLiveImage(pending))
  precondition(liveMessages[0].liveActivity?.tools[0].images?[0].state == "generating")
  persistTranscript()
  liveMessages = [] // Another call replaces the UI while generation finishes.
  let ready = ImageAttachment(id: "image-1", prompt: pending.prompt, fileURL: URL(fileURLWithPath: "/tmp/test-image.png"), status: .ready)
  precondition(receiveLiveImage(ready))
  let saved = SimpleConversationManager.shared.saved[0]
  precondition(saved.liveActivity?.tools[0].images?[0].state == "ready")
  precondition(saved.liveActivity?.tools[0].images?[0].url == "file:///tmp/test-image.png")
  precondition(!receiveLiveImage(ready)) // Completed routing is removed.
  precondition(!receiveLiveImage(ImageAttachment(prompt: "Unrelated")))
  print("PASS: generating placeholder, late image persistence after End, unrelated image isolation")
 }
}

extension LiveSession {
 static func testGalleryRouting() throws {
  let session = LiveSession()
  session.conversation = SimpleConversation(); session.state = .connected
  let work = UUID(); session.workID = work
  var row = MessageStruct(id: work.uuidString, role: "assistant", content: "Searching")
  row.liveActivity = LiveActivityRecord()
  session.liveMessages = [row]
  SkillDispatcher.shared.gallery = ImageGalleryAttachment(query: "Landscapes", items: [.init(thumbnailURL: "https://example.com/thumb.png", originalURL: "https://example.com/full.png", sourceLink: "https://example.com/page", title: "Landscape")])
  session.execute([FunctionCallStruct(name: "image_search", callId: "search")], index: 0, delegation: "opaque", work: work, remaining: 2, transcriptCount: 0)
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  let activity = session.liveMessages[0].liveActivity!
  let restored = try JSONDecoder().decode(LiveActivityRecord.self, from: JSONEncoder().encode(activity))
  precondition(restored.tools[0].images?.first?.sourceURL == "https://example.com/page")
  precondition(restored.tools[0].images?.first?.url == "https://example.com/full.png")
  precondition(restored.tools[0].images?.first?.thumbnailURL == "https://example.com/thumb.png")
  SkillDispatcher.shared.gallery = nil
  print("PASS: image search thumbnails, full images and source links survive serialization")
  let share = LiveSession(); share.conversation = SimpleConversation(); share.state = .connected
  let shareWork = UUID(); share.workID = shareWork
  row.id = shareWork.uuidString; share.liveMessages = [row]
  SkillDispatcher.shared.file = FileAttachment()
  share.execute([FunctionCallStruct(name: "share_file", callId: "share")], index: 0, delegation: "opaque", work: shareWork, remaining: 2, transcriptCount: 0)
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  precondition(share.liveMessages[0].liveActivity?.tools[0].images?.first?.url == "file:///tmp/example.png")
  precondition(share.liveMessages[0].liveActivity?.tools[0].images?.first?.state == "ready")
  SkillDispatcher.shared.file = nil
  print("PASS: share_file image attachments are rendered as Live image results")
 }
}

struct FileAttachment {
 init() {}
 init(id: String, fileURL: URL, fileName: String, kind: Kind, mimeType: String) {
  self.id = id; self.resolvedFileURL = fileURL; self.fileName = fileName; self.kind = kind
 }

 enum Kind { case image, pdf }
 enum Status { case ready, pending, failed }
 var id = "shared-image"
 var fileName = "example.png"
 var kind: Kind = .image
 var status: Status = .ready
 var failureReason: String? = nil
 var resolvedFileURL = URL(fileURLWithPath: "/tmp/example.png")
}

struct PDFAttachment {
    enum Status: Equatable {
        case generating
        case ready
        case failed
    }

    let id: String
    let title: String
    let template: String
    /// Source GFM markdown. Carried on the attachment so a retry from the
    /// failed-state UI can re-run the same render without round-tripping
    /// through the model.
    let document: String
    var fileURL: URL?
    var thumbnailURL: URL?
    var pageCount: Int?
    var status: Status
    var failureReason: String?
    /// Conversation the render belongs to (mirrors `ImageAttachment` for
    /// multi-tab Mac routing). Optional for single-tab callers.
    let conversationId: String?

    init(id: String = UUID().uuidString,
         title: String,
         template: String,
         document: String,
         fileURL: URL? = nil,
         thumbnailURL: URL? = nil,
         pageCount: Int? = nil,
         status: Status = .generating,
         failureReason: String? = nil,
         conversationId: String? = nil) {
        self.id = id
        self.title = title
        self.template = template
        self.document = document
        self.fileURL = fileURL
        self.thumbnailURL = thumbnailURL
        self.pageCount = pageCount
        self.status = status
        self.failureReason = failureReason
        self.conversationId = conversationId
    }
}


extension LiveSession {
 static func testPDFRouting() {
  SimpleConversationManager.shared.saved = []
  let session = LiveSession(); session.conversation = SimpleConversation(); session.state = .connected
  let work = UUID(); session.workID = work
  var request = MessageStruct(id: work.uuidString, role: "assistant", content: "Creating NDA")
  request.liveActivity = LiveActivityRecord()
  session.liveMessages = [request]
  var pdf = PDFAttachment(id: "nda", title: "NDA", template: "contract", document: "Test document")
  session.registerLivePDF(pdf, requestID: work.uuidString)
  precondition(session.receiveLivePDF(pdf)) // Suppresses the normal host and its conversation switch.
  precondition(session.state == .connected && session.liveMessages.count == 2)
  precondition(session.liveMessages.last?.pdfAttachment?.status == .generating)
  session.persistTranscript()
  session.liveMessages = []
  session.generation = UUID() // Another Live call starts in the same conversation.
  session.persisted = false
  pdf.status = .ready; pdf.fileURL = URL(fileURLWithPath: "/tmp/nda.pdf")
  precondition(session.receiveLivePDF(pdf))
  let saved = SimpleConversationManager.shared.saved
  precondition(saved.count == 2 && session.liveMessages.isEmpty)
  precondition(saved.last?.fileAttachment?.kind == .pdf)
  precondition(saved.last?.fileAttachment?.resolvedFileURL.path == "/tmp/nda.pdf")
  precondition(!session.receiveLivePDF(pdf))
  precondition(!session.receiveLivePDF(PDFAttachment(title: "Other", template: "notes", document: "Unrelated")))
  let retry = LiveSession(); retry.conversation = SimpleConversation(); retry.state = .connected
  retry.liveMessages = [request]
  var failed = PDFAttachment(id: "retry", title: "NDA", template: "contract", document: "Test document")
  retry.registerLivePDF(failed, requestID: work.uuidString)
  precondition(retry.receiveLivePDF(failed))
  failed.status = .failed; failed.failureReason = "Render failed"
  precondition(retry.receiveLivePDF(failed))
  precondition(retry.liveMessages.last?.content.contains("Render failed") == true)
  failed.status = .generating
  precondition(retry.receiveLivePDF(failed))
  failed.status = .ready; failed.fileURL = URL(fileURLWithPath: "/tmp/retry.pdf")
  precondition(retry.receiveLivePDF(failed))
  precondition(retry.liveMessages.count == 2 && retry.state == .connected)
  print("PASS: Live PDF placeholder, late durable result, new-call isolation, failure and retry")
 }
 static func testSlowWork() {
  let session = LiveSession(); session.conversation = SimpleConversation(); session.state = .connected
  let work = UUID(); session.workID = work; session.thinking = true; session.delegations = ["slow"]
  let before = Cloud.connection.requests
  session.reportSlowWork(work: work, delegation: "slow")
  precondition(session.state == .connected && session.workID == work && session.thinking)
  precondition(session.delegations == ["slow"] && Cloud.connection.requests == before)
  session.complete("File ready", delegation: "slow", work: work)
  precondition(session.state == .connected && session.workID == nil && !session.thinking)
  session.status = "Listening"
  session.reportSlowWork(work: work, delegation: "slow")
  precondition(session.status == "Listening")
  print("PASS: slow work keeps call and request alive, no replay, completion and stale timer handling")
 }
}
