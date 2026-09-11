// Run with: swiftc LoopIOS/Live/LiveProtocol.swift scripts/test_live_protocol.swift -o /tmp/test-live && /tmp/test-live
import Foundation

@main
struct LiveProtocolTests {
    static func main() throws {
        let request = LiveProtocol.start(history: [("system", "private instruction"), ("user", "Hello"), ("assistant", "Hi"), ("function", "private tool data")])
        let session = request["session"] as! [String: Any]
        precondition(request["type"] as? String == "session.start")
        precondition(session["model"] as? String == "gpt-live-1")
        precondition((session["delegation"] as? [String: String])?["type"] == "client")
        let input = session["input"] as! [[String: Any]]
        precondition(input.count == 2)
        precondition(input[0]["role"] as? String == "user")
        precondition(input[1]["role"] as? String == "assistant")
        let large = LiveProtocol.start(history: (0..<200).map { _ in ("user", String(repeating: "a", count: 100)) })
        let bounded = (large["session"] as! [String: Any])["input"] as! [[String: Any]]
        precondition(bounded.count == 60)
        let many = LiveProtocol.start(history: (0..<200).map { _ in ("user", "x") })
        precondition(((many["session"] as! [String: Any])["input"] as! [[String: Any]]).count == 128)
        let result = String(repeating: "結果 🧑🏽‍💻 é confirmed. ", count: 200)
        let events = LiveProtocol.commentary(result, delegationID: "opaque_item_123")
        precondition(events.count > 1)
        precondition(events.allSatisfy { ($0["content"] as! String).utf8.count <= 450 })
        precondition(events.allSatisfy { $0["delegation_id"] as? String == "opaque_item_123" })
        precondition(events.map { $0["content"] as! String }.joined() == result)
        precondition(Set(events.map { $0["event_id"] as! String }).count == events.count)
        _ = try JSONSerialization.data(withJSONObject: request)
        _ = try JSONSerialization.data(withJSONObject: events)
        print("PASS: startup schema, history privacy/order/bounds, Unicode result chunks, delegation IDs")
    }
}
