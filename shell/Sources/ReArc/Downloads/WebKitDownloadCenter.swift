import CoreServices
import Foundation
import SidebarModel
import WebKit

/// WebKit's downloads for the tray: one `WKDownload` per item, saved without
/// asking into the controller's directory (uniquified like Chromium), with
/// progress from `WKDownload.progress`. Pause is cancel-with-resume-data and
/// resume is `WKWebView.resumeDownload(fromResumeData:)`, mapped back onto
/// the same row. WebKit runs no Safe Browsing check, so these items never
/// carry a danger state. Finished files get the quarantine attribute.
final class WebKitDownloadCenter: NSObject, DownloadBackend {
    weak var controller: DownloadsController?
    /// "Ask where to save": the save panel, as a sheet on the downloading page's window.
    var filePanels: FilePanelPresenting = SystemFilePanelPresenter()

    private struct Item {
        var download: WKDownload?
        weak var webView: WKWebView?
        var url: String
        var targetPath = ""
        var mimeType = ""
        var received: Int64 = 0
        var total: Int64 = 0
        var resumeData: Data?
        var observation: NSKeyValueObservation?
        var lastEmit = Date.distantPast
    }

    private var items: [String: Item] = [:]
    private var idsByDownload: [ObjectIdentifier: String] = [:]
    /// Items being paused or cancelled by the shell: their failure callback is expected.
    private var suppressedFailures: Set<String> = []
    /// The download folder's file-system calls (a free name, the finished
    /// file's size, quarantine), kept off the main thread: the folder can be
    /// on a slow volume or one macOS asks the user about.
    private let files = DispatchQueue(label: "net.rearc.webkit-download-files", qos: .userInitiated)

    /// Chromium-like decision: attachments, and main-frame responses WebKit cannot show.
    static func shouldDownload(response: URLResponse, canShowMIMEType: Bool, isForMainFrame: Bool) -> Bool {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return true
        }
        return isForMainFrame && !canShowMIMEType
    }

    func adopt(_ download: WKDownload, sourceURL: URL?, reusing existing: String? = nil) {
        let id = existing ?? UUID().uuidString
        download.delegate = self
        idsByDownload[ObjectIdentifier(download)] = id
        var item = items[id] ?? Item(url: sourceURL?.absoluteString ?? download.originalRequest?.url?.absoluteString ?? "")
        item.download = download
        item.webView = download.webView
        item.resumeData = nil
        item.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak download] progress, _ in
            let completed = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let self, let download else { return }
                self.progressed(download, received: completed, total: total)
            }
        }
        items[id] = item
        if existing == nil { controller?.noteOrigin(Self.origin(of: download.webView), for: id) }
        emit(id, kind: existing == nil ? .created : .updated)
    }

    /// The page a download started on. A private window's (non-persistent
    /// store), or one with no page, reports nothing and is never tidied.
    static func origin(of webView: WKWebView?) -> DownloadOrigin {
        guard let webView, webView.configuration.websiteDataStore.isPersistent else {
            return DownloadOrigin(page: TidyDownloads.Origin(), isPrivate: true)
        }
        return DownloadOrigin(page: TidyDownloads.Origin(pageTitle: webView.title, pageHost: webView.url?.host()), isPrivate: false)
    }

    // MARK: DownloadBackend

    func perform(_ action: DownloadAction, id: String) -> Bool {
        guard var item = items[id] else { return false }
        switch action {
        case .pause:
            guard let download = item.download else { return true }
            suppressedFailures.insert(id)
            download.cancel { [weak self] data in
                DispatchQueue.main.async {
                    guard let self, var item = self.items[id] else { return }
                    item.download = nil
                    item.resumeData = data
                    self.items[id] = item
                    self.emit(id, kind: .updated, paused: true)
                }
            }
        case .resume:
            guard item.download == nil, let data = item.resumeData, let webView = item.webView else { return true }
            item.resumeData = nil
            items[id] = item
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                self?.adopt(download, sourceURL: nil, reusing: id)
            }
        case .cancel, .remove:
            let active = item.download != nil || item.resumeData != nil
            if let download = item.download {
                suppressedFailures.insert(id)
                download.cancel(nil)
            }
            item.download = nil
            item.resumeData = nil
            item.observation = nil
            items[id] = item
            if active {
                if !item.targetPath.isEmpty { try? FileManager.default.removeItem(atPath: item.targetPath) }
                emit(id, kind: .cancelled, state: .cancelled)
            }
            if action == .remove { forget(id) }
        case .open, .reveal:
            return false
        }
        return true
    }

    func directoryChanged(_ directory: URL) {}

    // MARK: Progress and completion

    private func progressed(_ download: WKDownload, received: Int64, total: Int64) {
        guard let id = idsByDownload[ObjectIdentifier(download)], var item = items[id] else { return }
        item.received = max(received, 0)
        if total > 0 { item.total = total }
        items[id] = item
        // Throttled: the tray needs a few updates a second, not every chunk.
        guard Date().timeIntervalSince(item.lastEmit) >= 0.25 else { return }
        emit(id, kind: .updated)
    }

    private func emit(
        _ id: String,
        kind: DownloadEvent.Kind,
        state: DownloadState = .inProgress,
        paused: Bool = false,
        interruptReason: UInt32 = 0
    ) {
        guard var item = items[id] else { return }
        item.lastEmit = Date()
        items[id] = item
        controller?.apply(DownloadEvent(
            kind: kind,
            guid: id,
            url: item.url,
            targetPath: item.targetPath,
            mimeType: item.mimeType,
            receivedBytes: item.received,
            totalBytes: item.total,
            state: state,
            interruptReason: interruptReason,
            isPaused: paused,
            canResume: item.resumeData != nil
        ), source: .webKit)
    }

    private func forget(_ id: String) {
        if let download = items[id]?.download { idsByDownload[ObjectIdentifier(download)] = nil }
        items[id] = nil
        suppressedFailures.remove(id)
    }

    private func id(for download: WKDownload) -> String? {
        idsByDownload[ObjectIdentifier(download)]
    }

    /// Marks a finished file as downloaded from the web (Gatekeeper, "downloaded from" in Finder).
    private static func quarantine(_ path: String, origin: String) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "ReArc",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let origin = URL(string: origin) { properties[kLSQuarantineDataURLKey as String] = origin }
        values.quarantineProperties = properties
        try? url.setResourceValues(values)
    }
}

extension WebKitDownloadCenter: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let id = id(for: download), let controller, items[id] != nil else {
            return completionHandler(nil)
        }
        let directory = controller.directory
        guard controller.askWhereToSave else {
            files.async { [weak self] in
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = DownloadFormat.uniqueDestination(for: suggestedFilename, in: directory) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                DispatchQueue.main.async {
                    guard let self else { return completionHandler(nil) }
                    self.start(id, at: destination, response: response, completionHandler: completionHandler)
                }
            }
            return
        }
        files.async { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let request = FileChooserRequest(id: 0, mode: .save, defaultPath: directory.appendingPathComponent(suggestedFilename).path)
        _ = filePanels.present(request, in: download.webView?.window) { [weak self] urls in
            guard let self else { return completionHandler(nil) }
            guard let destination = urls?.first else {
                // Cancelled in the panel: the download never starts and leaves the tray.
                completionHandler(nil)
                self.suppressedFailures.insert(id)
                self.items[id]?.download = nil
                self.controller?.perform(.remove, on: id)
                return
            }
            // The panel already confirmed replacing an existing file.
            self.files.async { [weak self] in
                try? FileManager.default.removeItem(at: destination)
                DispatchQueue.main.async {
                    guard let self else { return completionHandler(nil) }
                    self.start(id, at: destination, response: response, completionHandler: completionHandler)
                }
            }
        }
    }

    private func start(_ id: String, at destination: URL, response: URLResponse, completionHandler: @escaping (URL?) -> Void) {
        guard var item = items[id] else { return completionHandler(nil) }
        item.targetPath = destination.path
        item.mimeType = response.mimeType ?? ""
        if response.expectedContentLength > 0 { item.total = response.expectedContentLength }
        if item.url.isEmpty, let url = response.url { item.url = url.absoluteString }
        items[id] = item
        emit(id, kind: .updated)
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(for: download), var item = items[id] else { return }
        item.download = nil
        item.observation = nil
        items[id] = item
        idsByDownload[ObjectIdentifier(download)] = nil
        let path = item.targetPath, origin = item.url
        files.async { [weak self] in
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
            Self.quarantine(path, origin: origin)
            DispatchQueue.main.async {
                guard let self, var item = self.items[id] else { return }
                if item.total <= 0 { item.total = item.received }
                if let size {
                    item.received = size
                    item.total = max(item.total, size)
                }
                self.items[id] = item
                self.emit(id, kind: .completed, state: .complete)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = id(for: download), var item = items[id] else { return }
        idsByDownload[ObjectIdentifier(download)] = nil
        if suppressedFailures.remove(id) != nil { return }
        item.download = nil
        item.observation = nil
        item.resumeData = resumeData
        items[id] = item
        let nsError = error as NSError
        // Chromium's interrupt groups: network 20, file 1.
        let reason: UInt32 = nsError.domain == NSURLErrorDomain ? 20 : 1
        emit(id, kind: .interrupted, state: .interrupted, interruptReason: reason)
    }
}
