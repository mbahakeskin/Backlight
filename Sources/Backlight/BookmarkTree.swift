import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The bookmarks panel with nothing searched: folders that open and close, and
/// the bookmarks in them. A bookmark or a folder is dragged onto a folder to go
/// into it, or onto the empty space below to go to the top; its menu moves it
/// too, and a folder's menu makes a folder in it, renames it or deletes it (what
/// was in it goes up a level, nothing is lost).
struct BookmarkTree: View {
    let window: BrowserWindow
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode (see PanelView).
    private var _open = State(initialValue: Set<UUID>())
    private var open: Set<UUID> {
        get { _open.wrappedValue }
        nonmutating set { _open.wrappedValue = newValue }
    }
    private var _target = State(initialValue: UUID?.none)
    /// The folder a drag is over, lit.
    private var target: UUID? {
        get { _target.wrappedValue }
        nonmutating set { _target.wrappedValue = newValue }
    }

    init(window: BrowserWindow) { self.window = window }

    var body: some View {
        let bookmarks = Bookmarks.shared
        VStack(alignment: .leading, spacing: 1) {
            if bookmarks.marks.isEmpty && bookmarks.folders.isEmpty {
                Text("No bookmarks yet. ⌘D keeps the page you are on.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            level(nil, depth: 0)
            // Room below to drop on: the top level.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 60)
                .contentShape(Rectangle())
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    BookmarkTree.dropped(providers, into: nil)
                    return true
                }
        }
    }

    private func level(_ folder: UUID?, depth: Int) -> AnyView {
        let inside = Bookmarks.shared.inside(folder)
        return AnyView(Group {
            ForEach(inside.folders) { child in
                folderRow(child, depth: depth)
                if open.contains(child.id) { level(child.id, depth: depth + 1) }
            }
            ForEach(inside.marks) { mark in
                PanelRow(title: mark.title, url: mark.url, detail: nil) {
                    window.openFromPanel(mark.url)
                } remove: {
                    Bookmarks.shared.remove([mark.id])
                }
                .padding(.leading, CGFloat(depth) * 20)
                .onDrag { NSItemProvider(object: "bookmark:\(mark.id.uuidString)" as NSString) }
                .contextMenu { moveMenu(bookmark: mark.id, now: mark.folder) }
            }
        })
    }

    private func folderRow(_ folder: Bookmarks.Folder, depth: Int) -> some View {
        let isOpen = open.contains(folder.id)
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: isOpen ? "folder" : "folder.fill").foregroundStyle(.secondary)
            Text(folder.name).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(Bookmarks.shared.count(in: folder.id))").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(target == folder.id ? 0.12 : 0)))
        .contentShape(Rectangle())
        .padding(.leading, CGFloat(depth) * 20)
        .onTapGesture {
            if isOpen { open.remove(folder.id) } else { open.insert(folder.id) }
        }
        .onDrag { NSItemProvider(object: "folder:\(folder.id.uuidString)" as NSString) }
        .onDrop(of: [.text], isTargeted: Binding(get: { target == folder.id }, set: { target = $0 ? folder.id : (target == folder.id ? nil : target) })) { providers in
            BookmarkTree.dropped(providers, into: folder.id)
            open.insert(folder.id)
            return true
        }
        .contextMenu {
            Button("New Folder Inside…") {
                if let name = BookmarkTree.askName("New Folder", value: "") {
                    Bookmarks.shared.makeFolder(name, in: folder.id)
                    open.insert(folder.id)
                }
            }
            Button("Rename…") {
                if let name = BookmarkTree.askName("Rename Folder", value: folder.name) { Bookmarks.shared.rename(folder.id, to: name) }
            }
            moveMenu(folder: folder.id, now: folder.parent)
            Divider()
            Button("Delete Folder") { Bookmarks.shared.deleteFolder(folder.id) }
        }
    }

    /// Where a bookmark or a folder can go: the top, or any folder (not a folder into itself).
    @ViewBuilder private func moveMenu(bookmark: UUID? = nil, folder: UUID? = nil, now: UUID?) -> some View {
        let bookmarks = Bookmarks.shared
        Menu("Move To") {
            Button("Top Level") { place(bookmark: bookmark, folder: folder, into: nil) }.disabled(now == nil)
            let all = bookmarks.folders
                .filter { $0.id != folder }
                .map { (id: $0.id, path: bookmarks.path(of: $0.id).joined(separator: " / ")) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            if !all.isEmpty { Divider() }
            ForEach(all, id: \.id) { entry in
                Button(entry.path) { place(bookmark: bookmark, folder: folder, into: entry.id) }.disabled(now == entry.id)
            }
        }
    }

    private func place(bookmark: UUID?, folder: UUID?, into: UUID?) {
        if let bookmark { Bookmarks.shared.move(bookmark, to: into) }
        if let folder { Bookmarks.shared.moveFolder(folder, to: into) }
        if let into { open.insert(into) }
    }

    /// What was dropped: "bookmark:<id>" or "folder:<id>", into a folder or the top.
    static func dropped(_ providers: [NSItemProvider], into folder: UUID?) {
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let said = value as? String else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let parts = said.split(separator: ":", maxSplits: 1).map(String.init)
                        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return }
                        if parts[0] == "bookmark" { Bookmarks.shared.move(id, to: folder) }
                        if parts[0] == "folder" { Bookmarks.shared.moveFolder(id, to: folder) }
                    }
                }
            }
        }
    }

    /// A name asked for in a small dialog; nil when cancelled or left empty.
    static func askName(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: title == "New Folder" ? "Create" : "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.placeholderString = "Name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
