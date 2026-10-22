import Foundation
import Observation
import AppKit

/// User-owned annotations only. Provider files remain read-only.
@MainActor @Observable final class SessionLibrary {
    private(set) var entries: [String: SessionAnnotation] = [:]
    private(set) var storageError: String?
    private(set) var hasUnsavedChanges = false
    @ObservationIgnored let url: URL
    @ObservationIgnored private var readOnly = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    private struct Document: Codable { var version = 1; var entries: [String: SessionAnnotation] }

    init(url: URL = SessionLibrary.defaultURL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
                entries = document.entries
            } catch {
                readOnly = true
                storageError = "Could not read the session library. The existing file is preserved: \(url.path). \(error.localizedDescription)"
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SessionMonitor/library.json")
    }
    var canEdit: Bool { !readOnly }
    func annotation(for id: String) -> SessionAnnotation { entries[id] ?? SessionAnnotation() }
    func apply(to original: Session) -> Session {
        guard let override = entries[original.id]?.statusOverride else { return original }
        var session = original
        session.detectedState = original.state
        session.state = override; session.confidence = .manual
        session.evidence = "Your local override is \(override.label). Detected state: \(original.state.label) (\(original.confidence.label)). " + original.evidence
        return session
    }
    func toggleBookmark(_ session: Session) {
        update(session) { entry in
            entry.bookmarked.toggle()
            if entry.bookmarked { entry.bookmarkedAt = Date() }
        }
    }
    func setNotes(_ notes: String, session: Session) {
        guard annotation(for: session.id).notes != notes else { return }
        let isNew = entries[session.id] == nil
        update(session) { entry in
            entry.notes = notes
            if isNew && !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.bookmarked = true; entry.bookmarkedAt = Date()
            }
        }
    }
    func setOverride(_ state: SessionState?, session: Session) {
        update(session) { $0.statusOverride = state }
    }
    func recordSourceArchive(_ session: Session) {
        guard entries[session.id] != nil else { return }
        update(session) { $0.archivedInSourceAt = Date() }
    }
    func remember(_ sessions: [Session]) {
        guard !readOnly else { return }
        var changed = false
        for session in sessions where entries[session.id] != nil {
            if entries[session.id]?.archivedInSourceAt != nil {
                entries[session.id]?.archivedInSourceAt = nil; changed = true
            }
            let saved = Self.snapshot(session)
            if entries[session.id]?.savedSession != saved {
                entries[session.id]?.savedSession = saved; changed = true
            }
        }
        if changed { scheduleSave() }
    }
    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard hasUnsavedChanges, !readOnly else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(entries: entries))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            hasUnsavedChanges = false; storageError = nil
        } catch { storageError = "Notes and bookmarks have not been saved: \(error.localizedDescription)" }
    }
    private func update(_ session: Session, mutation: (inout SessionAnnotation) -> Void) {
        guard !readOnly else { return }
        var entry = annotation(for: session.id)
        mutation(&entry)
        entry.savedSession = Self.snapshot(session)
        entries[session.id] = entry
        scheduleSave()
    }
    private func scheduleSave() {
        hasUnsavedChanges = true; saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.flush()
        }
    }
    private static func snapshot(_ original: Session) -> Session {
        var session = original
        // Never persist a display override as provider evidence.
        if let detected = session.detectedState {
            session.state = detected; session.confidence = .unavailable
            session.evidence = "Saved metadata; refresh the source to verify its current state."
        }
        session.detectedState = nil; session.savedBookmark = false
        return session
    }
}
