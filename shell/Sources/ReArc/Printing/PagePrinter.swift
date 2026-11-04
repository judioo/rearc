import AppKit
import PDFKit
import SidebarModel
import UniformTypeIdentifiers
import WebKit
#if REARC_CHROMIUM
import ReArcEngine
#endif

/// A page that can print and export itself as PDF. Chromium (ABI 1.28)
/// renders a PDF the shell prints with NSPrintOperation; WebKit prints its
/// view (`WKWebView.printOperation`) and exports `createPDF`.
protocol PagePrinting: AnyObject {
    var pageTitle: String? { get }
    var currentURL: URL? { get }
    /// The window showing the page; its print panel and save panel are sheets on it.
    var printWindow: NSWindow? { get }
    /// PDF bytes for Export as PDF, laid out on `paper` where the engine paginates.
    @MainActor func makePDF(for paper: PrintPaperSetup) async throws -> Data
    @MainActor func makePrintOperation(printInfo: NSPrintInfo) async throws -> NSPrintOperation
}

enum PagePrintError: LocalizedError {
    case unsupported
    case engine(String)
    case notPDF
    case noPages

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This page can't be printed."
        case .engine(let reason): return "The page couldn't be rendered for printing (\(reason))."
        case .notPDF: return "The page didn't produce a PDF."
        case .noPages: return "The PDF has no pages."
        }
    }
}

/// Runs a print operation; the self-test records it instead of opening the panel.
protocol PrintOperationRunning {
    func run(_ operation: NSPrintOperation, in window: NSWindow?, completion: @escaping (Bool) -> Void)
}

/// Asks where to save an exported PDF.
protocol PDFDestinationChoosing {
    func chooseDestination(suggestedName: String, in window: NSWindow?, completion: @escaping (URL?) -> Void)
}

/// The native print panel, as a sheet on the page's window (app-modal without one).
struct SheetPrintRunner: PrintOperationRunning {
    func run(_ operation: NSPrintOperation, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        guard let window, window.isVisible else {
            completion(operation.run())
            return
        }
        let delegate = PrintSheetDelegate(completion)
        operation.runModal(
            for: window,
            delegate: delegate,
            didRun: #selector(PrintSheetDelegate.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: Unmanaged.passRetained(delegate).toOpaque()
        )
    }
}

private final class PrintSheetDelegate: NSObject {
    let completion: (Bool) -> Void

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintSheetDelegate>.fromOpaque(contextInfo).release() }
        completion(success)
    }
}

struct SavePanelPDFChooser: PDFDestinationChoosing {
    func chooseDestination(suggestedName: String, in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export as PDF"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        if let window, window.isVisible {
            panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.url : nil) }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

/// Cmd+P, the page's window.print() and File > Export as PDF… for any page
/// (tabs, split panes, peek, Little Arc, private windows). One job per page.
/// Main thread only.
final class PagePrinter {
    static let shared = PagePrinter()

    var runner: PrintOperationRunning = SheetPrintRunner()
    var destinationChooser: PDFDestinationChoosing = SavePanelPDFChooser()
    /// Failures are shown as a sheet unless this is set (self-test).
    var onError: ((Error) -> Void)?
    private var gate = PrintRequestGate<ObjectIdentifier>()
    /// Requests dropped because that page was already printing.
    private(set) var droppedRequests = 0

    func isPrinting(_ page: PagePrinting) -> Bool { gate.isPrinting(ObjectIdentifier(page)) }

    /// The paper the print panel starts with (NSPrintInfo.shared: the user's last choice or the locale's).
    static var defaultPaper: PrintPaperSetup {
        let info = NSPrintInfo.shared
        return PrintPaperSetup(
            paperWidthPoints: info.paperSize.width,
            heightPoints: info.paperSize.height,
            landscape: info.orientation == .landscape
        )
    }

    func print(_ page: PagePrinting) {
        let key = ObjectIdentifier(page)
        guard gate.begin(key) else {
            droppedRequests += 1
            return
        }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let window = page.printWindow
        Task { @MainActor in
            do {
                let operation = try await page.makePrintOperation(printInfo: printInfo)
                operation.jobTitle = String(PDFExportNaming.suggestedFileName(title: page.pageTitle, url: page.currentURL).dropLast(4))
                // PagePrinter is immortal (shared); the panel ends the job.
                self.runner.run(operation, in: window) { _ in self.gate.end(key) }
            } catch {
                self.gate.end(key)
                self.report(error, in: window)
            }
        }
    }

    /// File > Export as PDF…: asks where, then writes the page's PDF there.
    func exportPDF(_ page: PagePrinting, completion: ((Result<URL, Error>) -> Void)? = nil) {
        let key = ObjectIdentifier(page)
        guard gate.begin(key) else {
            droppedRequests += 1
            return
        }
        let window = page.printWindow
        let name = PDFExportNaming.suggestedFileName(title: page.pageTitle, url: page.currentURL)
        destinationChooser.chooseDestination(suggestedName: name, in: window) { [weak self] url in
            guard let self else { return }
            guard let url else {
                self.gate.end(key)
                return
            }
            Task { @MainActor in
                do {
                    let data = try await page.makePDF(for: Self.defaultPaper)
                    guard PDFSignature.isPDF(data) else { throw PagePrintError.notPDF }
                    try data.write(to: url, options: .atomic)
                    self.gate.end(key)
                    completion?(.success(url))
                } catch {
                    self.gate.end(key)
                    if let completion { completion(.failure(error)) } else { self.report(error, in: window) }
                }
            }
        }
    }

    /// Prints PDF bytes at their own size, shrunk only when the chosen paper is smaller.
    static func printOperation(forPDF data: Data, printInfo: NSPrintInfo) throws -> NSPrintOperation {
        guard PDFSignature.isPDF(data), let document = PDFDocument(data: data) else { throw PagePrintError.notPDF }
        guard document.pageCount > 0 else { throw PagePrintError.noPages }
        // The PDF carries the page margins; the sheet's own margins would shrink it again.
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        guard let operation = document.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            throw PagePrintError.notPDF
        }
        return operation
    }

    private func report(_ error: Error, in window: NSWindow?) {
        if let onError { return onError(error) }
        let alert = NSAlert()
        alert.messageText = "Couldn't print this page"
        alert.informativeText = error.localizedDescription
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - WebKit

extension WKEngine: PagePrinting {
    var printWindow: NSWindow? { webView.window }

    /// WebKit's Export as PDF (Safari's too): one page as tall as the document.
    @MainActor func makePDF(for paper: PrintPaperSetup) async throws -> Data {
        try await webView.pdf(configuration: WKPDFConfiguration())
    }

    @MainActor func makePrintOperation(printInfo: NSPrintInfo) async throws -> NSPrintOperation {
        let operation = webView.printOperation(with: printInfo)
        // WKWebView paginates its print view only once it has the page's size.
        operation.view?.frame = webView.bounds
        return operation
    }
}

/// `window.print()` on WebKit: there is no public print delegate, so a page
/// script forwards the call to the shell (beforeprint/afterprint do not fire).
final class PrintRequestMessageHandler: NSObject, WKScriptMessageHandler {
    static let handlerName = "rearcPrint"
    static let scriptSource = """
    (function() {
      var handler = window.webkit && window.webkit.messageHandlers['\(handlerName)'];
      if (!handler) return;
      window.print = function() { handler.postMessage(null); };
    })();
    """

    var onRequest: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        onRequest?()
    }
}

// MARK: - Chromium

#if REARC_CHROMIUM
extension ChromiumEngine: PagePrinting {
    var printWindow: NSWindow? { leaseHolder?.window ?? pagePrompts.hostWindow }

    @MainActor func makePDF(for paper: PrintPaperSetup) async throws -> Data {
        let (status, data) = await printToPDF(paper: paper)
        guard status == .rearcOK, let data else {
            throw status == ReArcStatus(REARC_UNSUPPORTED) ? PagePrintError.unsupported : PagePrintError.engine(status.rearcName)
        }
        return data
    }

    @MainActor func makePrintOperation(printInfo: NSPrintInfo) async throws -> NSPrintOperation {
        let paper = PrintPaperSetup(
            paperWidthPoints: printInfo.paperSize.width,
            heightPoints: printInfo.paperSize.height,
            landscape: printInfo.orientation == .landscape
        )
        return try PagePrinter.printOperation(forPDF: try await makePDF(for: paper), printInfo: printInfo)
    }
}
#endif
