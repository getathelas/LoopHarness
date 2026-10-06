import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Compile the production service and Markdown converter directly. Only the
// conversation/workspace shell is replaced; no model call or credentials needed.
final class Workspace {
    static let shared = Workspace()
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("LoopPDFPaginationTests")
}
protocol PDFSkillHost: AnyObject {
    func pdfSkillDidStartGenerating(_ attachment: PDFAttachment)
    func pdfSkillDidFinishGenerating(_ attachment: PDFAttachment)
}

final class PaginationChecks: NSObject, PDFSkillHost {
    let templates = ["contract", "letter", "notes", "report", "itinerary"]
    var index = 0
    var failures: [String] = []
    var results: [String] = []

    func start() {
        try! FileManager.default.createDirectory(at: Workspace.shared.rootURL, withIntermediateDirectories: true)
        PDFGenerationService.shared.host = self
        next()
    }

    func next() {
        guard index < templates.count * 2 else {
            let summary = (results + failures + [failures.isEmpty ? "PASS" : "FAIL"]).joined(separator: "\n")
            print(summary)
            try! summary.write(to: Workspace.shared.rootURL.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
            exit(failures.isEmpty ? 0 : 1)
        }
        let template = templates[index / 2]
        let long = index % 2 == 1
        let paragraphs = long ? 55 : 1
        var document = "*Pagination regression fixture*\n\n"
        for n in 0..<paragraphs {
            document += "Marker\(n)Z The contractor will inspect the irrigation system, repair damaged components, and confirm that all zones operate correctly. Completion includes a written record of the work and final inspection.\n\n"
        }
        document += "## Signatures\n\n| Owner | Contractor |\n| --- | --- |\n| Signature: ______ | Signature: ______ |\n| FinalMarkerZ | Date: ______ |"
        PDFGenerationService.shared.submit(title: "\(template) \(long ? "long" : "short")", document: document, template: template)
    }

    func pdfSkillDidStartGenerating(_ attachment: PDFAttachment) {
        FileHandle.standardError.write(Data("Rendering \(attachment.title)\n".utf8))
    }

    func pdfSkillDidFinishGenerating(_ attachment: PDFAttachment) {
        defer { index += 1; DispatchQueue.main.async { self.next() } }
        guard attachment.status == .ready, let url = attachment.fileURL,
              let pdf = PDFDocument(url: url) else {
            failures.append("FAIL \(attachment.title): \(attachment.failureReason ?? "missing PDF")")
            return
        }
        let long = index % 2 == 1
        if long && pdf.pageCount < 2 { failures.append("FAIL long document did not paginate") }
        if !long && index / 2 < 3 && pdf.pageCount != 1 { failures.append("FAIL short document has extra pages") }
        if !long && index / 2 >= 3 && pdf.pageCount != 2 { failures.append("FAIL cover must occupy exactly one separate page") }
        let allText = pdf.string ?? ""
        if !allText.lowercased().contains(attachment.title.lowercased()) { failures.append("FAIL document title missing") }
        for n in 0..<(long ? 55 : 1) {
            let marker = "Marker\(n)Z"
            if allText.components(separatedBy: marker).count != 2 { failures.append("FAIL missing/duplicated \(marker) in \(attachment.title)") }
        }
        if !allText.contains("FinalMarkerZ") { failures.append("FAIL final signature content missing") }
        for n in 0..<pdf.pageCount {
            let page = pdf.page(at: n)!
            let rect = page.bounds(for: .mediaBox)
            if abs(rect.width - 612) > 0.1 || abs(rect.height - 792) > 0.1 { failures.append("FAIL non-Letter page: \(rect)") }
            if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failures.append("FAIL blank page \(n)") }
        }
        results.append("\(attachment.title): \(pdf.pageCount) Letter pages — \(url.path)")
    }
}

#if os(macOS)
@main
final class HarnessApp: NSObject, NSApplicationDelegate {
    let checks = PaginationChecks()
    static func main() {
        let app = NSApplication.shared
        let delegate = HarnessApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { checks.start() }
}
#else
@main
final class HarnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let checks = PaginationChecks()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        checks.start()
        return true
    }
}
#endif
