import AppKit
import CryptoKit
import Foundation
import SwiftUI

private let baseURL = URL(string: "https://zenithcrown.net/files/")!

enum UpdaterError: LocalizedError {
    case missingChecksum(String)
    case checksumMismatch(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingChecksum(let file): return "No checksum found for \(file)"
        case .checksumMismatch(let file): return "Checksum verification failed for \(file)"
        case .invalidResponse: return "The update server returned an invalid response."
        }
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progressHandler: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var transferError: Error?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progressHandler = progress
    }

    func download(from url: URL) async throws {
        defer { session.invalidateAndCancel() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                throw UpdaterError.invalidResponse
            }
            let manager = FileManager.default
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
        } catch {
            transferError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let transferError {
            continuation.resume(throwing: transferError)
        } else {
            continuation.resume()
        }
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    @Published var clientFolder: URL?
    @Published var status = "Select your Zenith Crown Online client folder."
    @Published var detail = ""
    @Published var progress = 0.0
    @Published var isUpdating = false
    @Published var updateComplete = false
    @Published var logURL: URL?

    private func log(_ message: String) {
        guard let logURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            NSLog("Updater logging failed: %@", error.localizedDescription)
        }
    }

    private func beginLog(clientFolder: URL) throws {
        logURL = nil
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ZenithCrownUpdater", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("update-\(UUID().uuidString).log")
        try Data().write(to: url, options: .atomic)
        logURL = url
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        log("Updater \(version); client folder: \(clientFolder.path)")
        log("App: \(Bundle.main.bundleURL.path)")
    }

    func showLog() {
        guard let logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    func chooseClientFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Zenith Crown Online Client Folder"
        panel.prompt = "Select"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            clientFolder = url.standardizedFileURL
            status = "Ready to check for updates."
            detail = url.path
            updateComplete = false
        }
    }

    func startUpdate() {
        guard let clientFolder, !isUpdating else { return }
        isUpdating = true
        updateComplete = false
        progress = 0

        Task {
            do {
                try beginLog(clientFolder: clientFolder)
                try await update(clientFolder: clientFolder)
                log("Update complete; cleanup finished.")
                status = "Update complete."
                detail = "Your client files are ready."
                progress = 1
                updateComplete = true
            } catch {
                log("Update failed: \(error)")
                status = "Update failed."
                detail = error.localizedDescription
            }
            isUpdating = false
        }
    }

    func openClientFolder() {
        guard let clientFolder else { return }
        NSWorkspace.shared.open(clientFolder)
    }

    private func update(clientFolder: URL) async throws {
        status = "Downloading manifest and checksums..."
        detail = ""

        async let manifestData = fetchControlFile("manifest.txt")
        async let checksumData = fetchControlFile("checksums.txt")
        let (manifest, checksums) = try await (manifestData, checksumData)

        let plan = try UpdateManifest.parse(manifest, root: clientFolder)
        let files = plan.files
        var verified = Set<String>()
        log("Manifest: \(files.count) downloads, \(plan.deletes.count) deletion directives")
        log("Manifest MD5: \(Insecure.MD5.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined())")
        let remoteHashes = parseChecksums(checksums)

        for (index, file) in files.enumerated() {
            let fileNumber = index + 1
            status = "Checking file \(fileNumber) of \(files.count)"
            detail = file.remoteName

            let destination = try UpdateManifest.destination(root: clientFolder, relativePath: file.localPath)
            guard let expectedHash = remoteHashes[file.remoteName.lowercased()] else {
                throw UpdaterError.missingChecksum(file.remoteName)
            }

            if FileManager.default.fileExists(atPath: destination.path),
               try md5(destination) == expectedHash.lowercased() {
                verified.insert(destination.path)
                progress = Double(fileNumber) / Double(max(files.count, 1))
                continue
            }

            status = "Downloading \(fileNumber) of \(files.count)"
            let temporary = try UpdateManifest.destination(
                root: clientFolder, relativePath: file.localPath + ".\(UUID().uuidString).download"
            )
            defer { try? FileManager.default.removeItem(at: temporary) }
            let remoteURL = remoteFileURL(file.remoteName)
            let completedFileCount = index
            let totalFileCount = max(files.count, 1)
            let downloader = DownloadDelegate(destination: temporary) { [self] fileProgress in
                Task { @MainActor [self] in
                    progress = (Double(completedFileCount) + fileProgress) / Double(totalFileCount)
                }
            }
            try await downloader.download(from: remoteURL)

            detail = "Verifying \(file.remoteName)..."
            guard try md5(temporary) == expectedHash.lowercased() else {
                try? FileManager.default.removeItem(at: temporary)
                throw UpdaterError.checksumMismatch(file.remoteName)
            }

            // Recheck after the network await before changing the installed file.
            _ = try UpdateManifest.destination(root: clientFolder, relativePath: file.localPath)
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
            verified.insert(destination.path)
            progress = Double(fileNumber) / Double(max(files.count, 1))
        }

        status = "Removing obsolete files..."
        try plan.applyDeletes(root: clientFolder, verified: verified) { message in
            detail = message
            log(message)
        }
    }

    private func fetchControlFile(_ name: String) async throws -> String {
        var components = URLComponents(url: baseURL.appendingPathComponent(name), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: UUID().uuidString)]
        var request = URLRequest(url: components.url!)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw UpdaterError.invalidResponse
        }
        return text
    }

    private func parseChecksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2 else { continue }
            let hash = String(fields[0])
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard hash.count == 32 else { continue }
            result[name.lowercased()] = hash.lowercased()
        }
        return result
    }

    private func remoteFileURL(_ name: String) -> URL {
        name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .reduce(baseURL) { url, component in
                url.appendingPathComponent(String(component))
            }
    }

    private func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = Insecure.MD5()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ContentView: View {
    @StateObject private var updater = UpdaterModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Zenith Crown Online")
                .font(.title.bold())

            Text(updater.status)
                .font(.headline)

            Text(updater.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            ProgressView(value: updater.progress)
                .progressViewStyle(.linear)

            Text("\(Int(updater.progress * 100))%")
                .monospacedDigit()

            HStack {
                Button("Select Client Folder") {
                    updater.chooseClientFolder()
                }
                .disabled(updater.isUpdating)

                Button(updater.isUpdating ? "Updating..." : "Update") {
                    updater.startUpdate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(updater.clientFolder == nil || updater.isUpdating)

                if updater.logURL != nil {
                    Button("Show Log") { updater.showLog() }
                }

                if updater.updateComplete {
                    Button("Open Client Folder") {
                        updater.openClientFolder()
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 560, height: 260)
    }
}

@main
struct ZenithCrownUpdaterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
