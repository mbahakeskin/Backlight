import Foundation
import Observation

/// Pages kept on purpose, in the order you keep them, in bookmarks.json; and
/// folders to keep them in, in bookmark-folders.json beside it (a file of its
/// own, so an older Backlight still reads the bookmarks, all at the top). ⌘D
/// keeps the page you are on, or lets it go again.
@Observable
final class Bookmarks {
    /// The bookmarks of the profile in front.
    static var shared: Bookmarks { Profiles.active.bookmarks }

    struct Mark: Codable, Identifiable, Hashable {
        var id = UUID()
        var url: URL
        var title: String
        var added = Date()
        /// The folder it is in; none: at the top.
        var folder: UUID? = nil
    }

    /// A folder, in another one or at the top.
    struct Folder: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var parent: UUID? = nil
    }

    private(set) var marks: [Mark]
    private(set) var folders: [Folder]
    @ObservationIgnored private let file: String
    @ObservationIgnored private let foldersFile: String

    init(file: String) {
        self.file = file
        foldersFile = file.replacingOccurrences(of: "bookmarks", with: "bookmark-folders")
        let folders = Store.read(foldersFile, as: [Folder].self) ?? []
        self.folders = folders
        // A bookmark whose folder is gone (deleted by an older Backlight) is at the top.
        let known = Set(folders.map(\.id))
        marks = (Store.read(file, as: [Mark].self) ?? []).map { mark in
            var mark = mark
            if let folder = mark.folder, !known.contains(folder) { mark.folder = nil }
            return mark
        }
    }

    private func save() { Store.write(marks, to: file) }
    private func saveFolders() { Store.write(folders, to: foldersFile) }
    func appendImported(_ mark: Mark) { marks.append(mark) }
    func saveImported() { save(); saveFolders() }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return marks.contains { $0.url == url }
    }

    /// Keeps the page, or lets it go if it was kept. True when it is now kept.
    @discardableResult
    func toggle(_ url: URL, title: String) -> Bool {
        if let index = marks.firstIndex(where: { $0.url == url }) {
            marks.remove(at: index)
            save()
            return false
        }
        marks.append(Mark(url: url, title: title.isEmpty ? Address.pretty(url) : title))
        save()
        return true
    }

    func remove(_ ids: Set<UUID>) {
        marks.removeAll { ids.contains($0.id) }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        marks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func search(_ query: String) -> [Mark] {
        Fuzzy.ranked(marks, query, title: \.title, url: \.url)
    }

    // MARK: - folders

    /// What is right in a folder (none: the top), folders first, each in the order kept.
    func inside(_ folder: UUID?) -> (folders: [Folder], marks: [Mark]) {
        (folders.filter { $0.parent == folder }, marks.filter { $0.folder == folder })
    }

    /// How many bookmarks are in a folder, its folders' too.
    func count(in folder: UUID) -> Int {
        marks.filter { $0.folder == folder }.count + folders.filter { $0.parent == folder }.reduce(0) { $0 + count(in: $1.id) }
    }

    /// The names from the top down to the folder.
    func path(of folder: UUID?) -> [String] {
        var names: [String] = []
        var current = folder
        var seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted, let found = folders.first(where: { $0.id == id }) {
            names.insert(found.name, at: 0)
            current = found.parent
        }
        return names
    }

    @discardableResult
    func makeFolder(_ name: String, in parent: UUID? = nil) -> Folder {
        let folder = Folder(name: name, parent: parent)
        folders.append(folder)
        saveFolders()
        return folder
    }

    func rename(_ folder: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folder }), !name.isEmpty else { return }
        folders[index].name = name
        saveFolders()
    }

    /// The folder goes; what was in it goes up to where the folder was, nothing is lost.
    func deleteFolder(_ folder: UUID) {
        guard let gone = folders.first(where: { $0.id == folder }) else { return }
        for index in marks.indices where marks[index].folder == folder { marks[index].folder = gone.parent }
        for index in folders.indices where folders[index].parent == folder { folders[index].parent = gone.parent }
        folders.removeAll { $0.id == folder }
        save()
        saveFolders()
    }

    /// A bookmark into a folder (none: the top), at the end of it.
    func move(_ mark: UUID, to folder: UUID?) {
        guard let index = marks.firstIndex(where: { $0.id == mark }), marks[index].folder != folder else { return }
        var moved = marks.remove(at: index)
        moved.folder = folder
        marks.append(moved)
        save()
    }

    /// A folder into another one (none: the top); never into itself or one of its own.
    func moveFolder(_ folder: UUID, to parent: UUID?) {
        guard folder != parent, let index = folders.firstIndex(where: { $0.id == folder }), folders[index].parent != parent else { return }
        var above = parent
        while let id = above {
            if id == folder { return }
            above = folders.first { $0.id == id }?.parent
        }
        folders[index].parent = parent
        saveFolders()
    }

    /// The folder at these names from the top, made where missing (for what is brought in from another browser).
    func folder(at names: [String]) -> UUID? {
        var parent: UUID?
        for name in names where !name.isEmpty {
            if let found = folders.first(where: { $0.parent == parent && $0.name == name }) {
                parent = found.id
            } else {
                let made = Folder(name: name, parent: parent)
                folders.append(made)
                parent = made.id
            }
        }
        return parent
    }
}

/// Tabs put away (by hand, or by themselves after a while unseen): kept with
/// their history and scroll position, searchable, and brought back as they
/// were. 30 days, 1,000 at most, in archive.json.
@Observable
final class Archive {
    static let shared = Archive()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var tab: Session.SavedTab
        var date = Date()
    }

    private(set) var entries: [Entry]
    @ObservationIgnored private lazy var saver = Store.Debounced { [weak self] in
        guard let self else { return }
        Store.write(self.entries, to: "archive.json")
    }

    private init() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        entries = (Store.read("archive.json", as: [Entry].self) ?? []).filter { $0.date > cutoff }
    }

    /// How long a tab goes unseen before it is archived. Twelve hours, or
    /// `archive.hours` in the defaults; 0 means never.
    static var after: TimeInterval? {
        let set = UserDefaults.standard.object(forKey: "archive.hours") as? Double ?? 12
        return set > 0 ? set * 3600 : nil
    }

    func add(_ tab: Tab) {
        guard !tab.isPrivate, tab.url != nil else { return }
        entries.insert(Entry(tab: Session.snapshot(of: tab)), at: 0)
        if entries.count > 1000 { entries.removeLast(entries.count - 1000) }
        saver.poke()
    }

    /// Takes an entry out, to be opened again.
    func take(_ id: UUID) -> Session.SavedTab? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        saver.poke()
        return entry.tab
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        saver.poke()
    }

    func clear() {
        entries = []
        saver.flush()
    }

    func search(_ query: String) -> [Entry] {
        Fuzzy.ranked(entries, query, title: \.tab.title, url: \.tab.url)
    }

    func flush() { saver.flush() }
}
