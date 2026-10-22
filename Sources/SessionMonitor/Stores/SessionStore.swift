import Foundation
import Observation

enum SidebarScope: Hashable {
    case all, running, attention, review, bookmarks, worktrees, subagents, app(AgentApp), workspace(String), project(String)
    var title: String {
        switch self {
        case .all: "All sessions"
        case .running: "Running"
        case .attention: "Needs attention"
        case .review: "Response ready"
        case .bookmarks: "Bookmarks"
        case .worktrees: "Worktrees"
        case .subagents: "Subagents"
        case .app(let app): app.rawValue
        case .workspace(let path): URL(fileURLWithPath: path).lastPathComponent
        case .project(let name): name
        }
    }
}

@MainActor @Observable final class SessionStore {
    var snapshot = SessionSnapshot()
    var search = ""
    var scope: SidebarScope? = .all
    var selectedID: String?
    var refreshing = false
    var autoRefresh = true
    var detailSection: SessionDetailSection = .latest
    var showingSources = false
    var showingUsage = false
    var showingInspector = false
    var showingMessage = false
    var showingReviewConfirmation = false
    var reviewCandidates: [Session] = []
    var archiveCandidate: Session?
    var archivingID: String?
    var actionError: String?
    var loadingDetailsID: String?
    var loadingRelatedID: String?
    private var expandedRecords: [String: ExpandedRecord] = [:]
    private var requestedRelated = Set<String>()
    var reviews: ReviewAcknowledgements
    @ObservationIgnored private let reviewDefaults: UserDefaults
    var preferences = MonitorPreferences()
    let library: SessionLibrary
    @ObservationIgnored private let collector = SessionCollector()
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(library: SessionLibrary? = nil, reviewDefaults: UserDefaults = .standard) {
        self.library = library ?? SessionLibrary()
        self.reviewDefaults = reviewDefaults
        reviews = ReviewAcknowledgements(dates: reviewDefaults.dictionary(forKey: "reviewAcknowledgements") as? [String: Double] ?? [:])
    }

    var rawSessions: [Session] {
        var result = snapshot.sessions.map { expandedRecords[$0.id]?.apply(to: $0) ?? $0 }
        let loaded = Set(result.map(\.id))
        for entry in library.entries.values {
            guard var saved = entry.savedSession, !loaded.contains(saved.id) else { continue }
            saved.savedBookmark = true; saved.isOpen = false; saved.pid = nil
            saved.state = .unknown; saved.confidence = .historical
            if let archived = entry.archivedInSourceAt {
                saved.evidence = "Archived in \(saved.app.rawValue) \(archived.formatted(date: .abbreviated, time: .shortened)). Notes and this saved snapshot are kept locally. Restore the chat in its original app to resume it."
            } else { saved.evidence = "Saved session metadata is outside the current scan. Current state is unknown; the last message and workspace details are saved snapshots." }
            if saved.lastMessage != nil { saved.lastMessage?.coverage = "Saved message snapshot · outside the current scan" }
            result.append(saved)
        }
        return result
    }
    var allSessions: [Session] {
        rawSessions.map { library.annotation(for: $0.id).archivedInSourceAt != nil ? $0 : library.annotation(for: $0.id).statusOverride != nil ? library.apply(to: $0) : reviews.apply(to: $0) }
    }
    var recentIncludingSubagents: [Session] {
        let cutoff = preferences.days == 0 ? Date.distantPast : Date().addingTimeInterval(-Double(preferences.days) * 86400)
        return allSessions.filter { library.annotation(for: $0.id).archivedInSourceAt == nil && ($0.updatedAt >= cutoff || $0.isOpen || $0.state == .running || $0.state.needsAction) }
    }
    var recentSessions: [Session] { recentIncludingSubagents.filter { !$0.isSubagent } }
    var bookmarks: [Session] { allSessions.filter { library.annotation(for: $0.id).bookmarked } }
    var visibleSessions: [Session] {
        let base: [Session]
        switch scope ?? .all {
        case .bookmarks: base = bookmarks
        case .subagents: base = recentIncludingSubagents.filter(\.isSubagent)
        default: base = recentSessions
        }
        return base.filter { session in
            let matchesScope: Bool
            switch scope ?? .all {
            case .all, .bookmarks, .subagents: matchesScope = true
            case .running: matchesScope = session.state == .running
            case .attention: matchesScope = session.state.needsAction
            case .review: matchesScope = session.state == .responseReady
            case .worktrees: matchesScope = session.worktree?.isLinked == true
            case .app(let app): matchesScope = session.app == app
            case .workspace(let path): matchesScope = session.workspace == path
            case .project(let name): matchesScope = !session.workspace.isEmpty && ProjectGroup.workspaceName(session.workspace) == name
            }
            let text = session.searchText + " " + library.annotation(for: session.id).notes
            return matchesScope && (search.isEmpty || text.localizedCaseInsensitiveContains(search))
        }.sorted {
            if scope == .bookmarks {
                return (library.annotation(for: $0.id).bookmarkedAt ?? .distantPast) > (library.annotation(for: $1.id).bookmarkedAt ?? .distantPast)
            }
            return $0.state.priority == $1.state.priority ? $0.updatedAt > $1.updatedAt : $0.state.priority < $1.state.priority
        }
    }
    var projects: [ProjectGroup] { ProjectGroup.groups(for: recentSessions) }
    var workspaces: [String] {
        Set(recentSessions.map(\.workspace).filter { !$0.isEmpty }).sorted {
            let left = URL(fileURLWithPath: $0).lastPathComponent
            let right = URL(fileURLWithPath: $1).lastPathComponent
            return left == right ? $0 < $1 : left.localizedStandardCompare(right) == .orderedAscending
        }
    }
    func reconcileSelection() {
        if let selectedID, visibleSessions.contains(where: { $0.id == selectedID }) { return }
        selectedID = visibleSessions.first?.id
    }
    func session(for id: String) -> Session? { allSessions.first { $0.id == id } }
    func rawSession(for id: String) -> Session? { rawSessions.first { $0.id == id } }
    var selectedSession: Session? { selectedID.flatMap { session(for: $0) } }
    var runningCount: Int { recentSessions.filter { $0.state == .running }.count }
    var attentionCount: Int { recentSessions.filter { $0.state.needsAction }.count }
    var reviewCount: Int { recentSessions.filter { $0.state == .responseReady }.count }
    var idleCount: Int { recentSessions.filter { $0.state == .idle }.count }
    var menuTitle: String { runningCount == 0 && attentionCount == 0 ? "" : "\(runningCount) · \(attentionCount)" }

    func markReviewed(_ session: Session) {
        guard session.state == .responseReady, let completed = session.completedAt else { return }
        reviews.dates[session.id] = completed.timeIntervalSince1970
        reviewDefaults.set(reviews.dates, forKey: "reviewAcknowledgements")
    }
    var visibleReadyCount: Int { visibleSessions.filter { $0.state == .responseReady }.count }
    var visibleReviewableCount: Int { visibleSessions.filter { $0.state == .responseReady && $0.completedAt != nil }.count }
    func prepareReview() {
        reviewCandidates = visibleSessions.filter { $0.state == .responseReady && $0.completedAt != nil }
        showingReviewConfirmation = true
    }
    func markPreparedReviewed() {
        for candidate in reviewCandidates {
            guard let current = session(for: candidate.id), current.completedAt == candidate.completedAt else { continue }
            markReviewed(current)
        }
        reviewCandidates = []
    }
    func markVisibleReviewed() {
        for session in visibleSessions where session.state == .responseReady { markReviewed(session) }
    }
    func markVisibleReadyIdle() {
        for session in visibleSessions where session.state == .responseReady { setOverride(.idle, session: session) }
    }
    func archiveReason(_ session: Session) -> String? {
        SessionArchive.unavailableReason(rawSession(for: session.id) ?? session, codexHome: preferences.codexHome, executablePath: preferences.executable(.codex))
    }
    func archive(_ candidate: Session) async {
        guard archivingID == nil else { return }
        guard !refreshing else { actionError = "A refresh is in progress. Wait for it to finish before archiving."; return }
        archivingID = candidate.id
        defer { archivingID = nil }
        await refresh()
        guard let current = snapshot.sessions.first(where: { $0.id == candidate.id }) else {
            actionError = "This chat is no longer in the current scan. Check its state in the original app."; return
        }
        do {
            try await SessionArchive.archive(current, codexHome: preferences.codexHome, executablePath: preferences.executable(.codex))
            library.recordSourceArchive(current)
            snapshot.sessions.removeAll { $0.id == current.id }
            reconcileSelection()
            await refresh()
        } catch { actionError = error.localizedDescription }
    }
    func toggleBookmark(_ session: Session) { library.toggleBookmark(rawSession(for: session.id) ?? session) }
    func setOverride(_ status: SessionState?, session: Session) {
        library.setOverride(status, session: rawSession(for: session.id) ?? session)
        if status == nil {
            reviews.dates.removeValue(forKey: session.id)
            reviewDefaults.set(reviews.dates, forKey: "reviewAcknowledgements")
        }
    }
    func setNotes(_ notes: String, session: Session) { library.setNotes(notes, session: rawSession(for: session.id) ?? session) }
    func loadDetails(_ session: Session) async {
        guard loadingDetailsID == nil else { return }
        loadingDetailsID = session.id
        defer { loadingDetailsID = nil }
        if let detail = await collector.expandedDetails(session) {
            if expandedRecords.count >= 12 { expandedRecords.removeAll() }
            expandedRecords[session.id] = detail
        } else { actionError = "The source transcript is no longer readable. Refresh its source and try again." }
    }
    func hasExpandedDetails(_ session: Session) -> Bool { expandedRecords[session.id]?.matches(session) == true }
    func loadRelated(_ id: String) async {
        guard loadingRelatedID == nil else { return }
        if let session = session(for: id), !session.savedBookmark { selectRelated(id); return }
        guard !refreshing else { actionError = "A refresh is in progress. Try opening the related chat when it finishes."; return }
        guard requestedRelated.count < 32 else { actionError = "Up to 32 related chats can be pinned for inspection. Restart Session Monitor to clear these temporary pins."; return }
        loadingRelatedID = id
        defer { loadingRelatedID = nil }
        requestedRelated.insert(id)
        await refresh()
        if snapshot.sessions.contains(where: { $0.id == id }) { selectRelated(id) }
        else {
            requestedRelated.remove(id)
            actionError = "The related chat was not found in the configured local sources. It may be archived, deleted, or stored elsewhere."
        }
    }
    func resumeCommand(_ session: Session) -> String? {
        guard let executable = preferences.executable(session.app) else { return nil }
        return DesktopActions.resumeCommand(session, executable: executable, providerHome: preferences.providerHome(session))
    }
    func selectRelated(_ id: String) {
        guard let target = session(for: id) else { return }
        scope = target.isSubagent ? .subagents : .all
        search = ""
        if !recentIncludingSubagents.contains(where: { $0.id == id }) { preferences.days = 0 }
        selectedID = id; detailSection = .latest
    }
    func openLabel(_ session: Session) -> String {
        if library.annotation(for: session.id).archivedInSourceAt != nil { return "Open \(session.app.rawValue) app" }
        if session.app == .claude, session.isSubagent {
            guard let key = session.parentKey, let parent = rawSession(for: key) else { return "Open Claude" }
            return DesktopActions.openLabel(parent) == "Open session" ? "Open parent session" : "Resume parent in Terminal"
        }
        return DesktopActions.openLabel(session)
    }
    func openSelected() {
        guard let session = selectedSession else { return }
        do {
            if library.annotation(for: session.id).archivedInSourceAt != nil {
                try DesktopActions.openApplication(session.app); return
            }
            if session.app == .claude, session.isSubagent {
                if let key = session.parentKey, let parent = rawSession(for: key) { try DesktopActions.openSession(parent, executable: preferences.executable(parent.app), providerHome: preferences.providerHome(parent), allowDiscovery: false) }
                else { try DesktopActions.openApplication(.claude) }
            } else { try DesktopActions.openSession(session, executable: preferences.executable(session.app), providerHome: preferences.providerHome(session), allowDiscovery: false) }
        } catch { actionError = error.localizedDescription }
    }
    func openApplication(_ app: AgentApp) {
        do { try DesktopActions.openApplication(app) } catch { actionError = error.localizedDescription }
    }
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(max(2, preferences.refreshSeconds))) }
                catch { break }
                if autoRefresh && archivingID == nil { await refresh() }
            }
        }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        snapshot = await collector.scan(preferences.configuration, requestedRelated: requestedRelated)
        library.remember(snapshot.sessions)
        refreshing = false
    }
}
