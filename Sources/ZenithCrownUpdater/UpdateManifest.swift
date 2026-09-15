import Foundation
import Darwin

struct UpdateFile {
    let localPath: String
    let remoteName: String
}

struct DeleteFile {
    let localPath: String
    let replacementPath: String
}

enum ManifestError: LocalizedError {
    case invalid(String)
    case unsafePath(String)
    case deletionFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .unsafePath(let path): return "Unsafe update path rejected: \(path)"
        case .deletionFailed(let path, let reason): return "Could not delete \(path): \(reason)"
        }
    }
}

struct UpdateManifest {
    var files: [UpdateFile] = []
    var deletes: [DeleteFile] = []

    static func parse(_ text: String, root: URL) throws -> UpdateManifest {
        var plan = UpdateManifest()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("\\#delete|") {
                throw ManifestError.invalid("Remove the leading backslash before #delete in the manifest.")
            }
            let parts = line.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.lowercased().hasPrefix("#delete|") {
                guard parts.count == 3 else {
                    throw ManifestError.invalid("Use #delete|old-local-path|replacement-local-path")
                }
                plan.deletes.append(DeleteFile(localPath: parts[1], replacementPath: parts[2]))
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard parts.count == 2, !parts[1].isEmpty else {
                    throw ManifestError.invalid("Invalid manifest line: \(line)")
                }
                plan.files.append(UpdateFile(localPath: parts[0], remoteName: parts[1]))
            }
        }
        try plan.validate(root: root)
        return plan
    }

    func validate(root: URL) throws {
        // Reject case-only aliases even on case-sensitive disks, for Windows compatibility.
        var downloads = Set<String>()
        for file in files {
            let key = try Self.destination(root: root, relativePath: file.localPath).path.lowercased()
            guard downloads.insert(key).inserted else {
                throw ManifestError.invalid("Duplicate download target: \(file.localPath)")
            }
        }
        var deletions = Set<String>()
        for file in deletes {
            let key = try Self.destination(root: root, relativePath: file.localPath).path.lowercased()
            guard deletions.insert(key).inserted, !downloads.contains(key) else {
                throw ManifestError.invalid("Conflicting deletion: \(file.localPath)")
            }
            let replacement = try Self.destination(root: root, relativePath: file.replacementPath)
            guard downloads.contains(replacement.path.lowercased()) else {
                throw ManifestError.invalid("Deletion requires a manifest download for \(file.replacementPath)")
            }
        }
    }

    static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                return nil
            }
            throw error
        }
    }

    static func destination(root: URL, relativePath: String) throws -> URL {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.components(separatedBy: "/")
        let forbidden = CharacterSet(charactersIn: ":*?\"<>|\0")
        guard !parts.contains(where: {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(" ") || $0.hasSuffix(".") ||
                $0.rangeOfCharacter(from: forbidden) != nil
        }) else { throw ManifestError.unsafePath(relativePath) }
        let base = root.standardizedFileURL
        let target = base.appendingPathComponent(normalized).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else {
            throw ManifestError.unsafePath(relativePath)
        }
        var current = target
        while true {
            if let attributes = try attributesIfPresent(current) {
                let type = attributes[.type] as? FileAttributeType
                guard type != .typeSymbolicLink,
                      current != target || type == .typeRegular,
                      current == target || type == .typeDirectory else {
                    throw ManifestError.unsafePath(current.path)
                }
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
        return target
    }

    func applyDeletes(root: URL, verified: Set<String>, report: (String) -> Void) throws {
        try validate(root: root)
        // All downloads, not just the replacement GRF, must have passed verification.
        for file in files {
            let url = try Self.destination(root: root, relativePath: file.localPath)
            guard verified.contains(url.path), try Self.attributesIfPresent(url) != nil else {
                throw ManifestError.invalid("Download is not verified: \(file.localPath)")
            }
        }
        for deletion in deletes {
            let target = try Self.destination(root: root, relativePath: deletion.localPath)
            report("Delete target: \(target.path)")
            guard let attributes = try Self.attributesIfPresent(target) else {
                report("Already absent: \(target.path)")
                continue
            }
            let immutable = (attributes[.immutable] as? NSNumber)?.boolValue == true
            do {
                // Finder's Locked flag, unlike a POSIX read-only mode, prevents unlink.
                if immutable {
                    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: target.path)
                }
                // unlink never recursively removes a directory.
                guard target.path.withCString({ Darwin.unlink($0) }) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard try Self.attributesIfPresent(target) == nil else {
                    throw ManifestError.invalid("File still exists after deletion.")
                }
                report("Deleted: \(target.path)")
            } catch {
                if immutable, FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: target.path)
                }
                throw ManifestError.deletionFailed(target.path, error.localizedDescription)
            }
        }
    }
}
