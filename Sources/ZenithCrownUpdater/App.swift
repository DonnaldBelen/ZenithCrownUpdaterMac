import AppKit
import CryptoKit
import Foundation
import SwiftUI

private let baseURL = URL(string: "https://zenithcrown.net/files/")!

struct UpdateFile {
    let localPath: String
    let remoteName: String
}

enum UpdaterError: LocalizedError {
    case invalidManifestLine(String)
    case missingChecksum(String)
    case checksumMismatch(String)
    case unsafePath(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidManifestLine(let line): return "Invalid manifest line: \(line)"
        case .missingChecksum(let file): return "No checksum found for \(file)"
        case .checksumMismatch(let file): return "Checksum verification failed for \(file)"
        case .unsafePath(let path): return "Unsafe destination path rejected: \(path)"
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
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
        session.invalidateAndCancel()
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
                try await update(clientFolder: clientFolder)
                status = "Update complete."
                detail = "Your client files are ready."
                progress = 1
                updateComplete = true
            } catch {
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

        let files = try parseManifest(manifest)
        let remoteHashes = parseChecksums(checksums)

        for (index, file) in files.enumerated() {
            let fileNumber = index + 1
            status = "Checking file \(fileNumber) of \(files.count)"
            detail = file.remoteName

            let destination = try safeDestination(root: clientFolder, relativePath: file.localPath)
            guard let expectedHash = remoteHashes[file.remoteName.lowercased()] else {
                throw UpdaterError.missingChecksum(file.remoteName)
            }

            if FileManager.default.fileExists(atPath: destination.path),
               try md5(destination) == expectedHash.lowercased() {
                progress = Double(fileNumber) / Double(max(files.count, 1))
                continue
            }

            status = "Downloading \(fileNumber) of \(files.count)"
            let temporary = destination.appendingPathExtension("download")
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

            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
            progress = Double(fileNumber) / Double(max(files.count, 1))
        }
    }

    private func fetchControlFile(_ name: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent(name))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw UpdaterError.invalidResponse
        }
        return text
    }

    private func parseManifest(_ text: String) throws -> [UpdateFile] {
        try text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw UpdaterError.invalidManifestLine(line)
            }
            return UpdateFile(localPath: parts[0], remoteName: parts[1])
        }
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

    private func safeDestination(root: URL, relativePath: String) throws -> URL {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains(":") else {
            throw UpdaterError.unsafePath(relativePath)
        }
        let destination = root.appendingPathComponent(normalized).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard destination.path.hasPrefix(rootPath + "/") else {
            throw UpdaterError.unsafePath(relativePath)
        }
        return destination
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
