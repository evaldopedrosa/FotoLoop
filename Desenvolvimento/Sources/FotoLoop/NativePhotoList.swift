import AppKit
import SwiftUI

// Use AppKit's row drag lifecycle and insertion feedback; no competing SwiftUI gestures.
@MainActor
struct NativePhotoList: NSViewRepresentable {
    @ObservedObject var model: FotoLoopModel
    static let dragType = NSPasteboard.PasteboardType("com.evaldopedrosa.fotoloop.photo-order")

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let table = NSTableView()
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("photo"))
        column.minWidth = 180
        column.width = 280
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 82
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .inset
        table.backgroundColor = .textBackgroundColor
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityLabel("Frames in animation order")
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.sync(model)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.sync(model) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.clearImages()
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: FotoLoopModel
        weak var table: NSTableView?
        private var photos: [URL] = []
        private var session: UUID?
        private var syncing = false
        private var selection: URL?
        private let cells = NSHashTable<ThumbnailCell>.weakObjects()
        init(model: FotoLoopModel) { self.model = model }

        func sync(_ model: FotoLoopModel) {
            self.model = model
            let sessionChanged = session != model.sessionID
            let needsReload = sessionChanged || photos != model.photos
            if sessionChanged { clearImages() }
            photos = model.photos
            session = model.sessionID
            guard let table else { return }
            syncing = true
            if needsReload { table.reloadData() }
            let selectedIndex = model.selected.flatMap { photos.firstIndex(of: $0) }
            let indexes = selectedIndex.map { IndexSet(integer: $0) } ?? IndexSet()
            if indexes != table.selectedRowIndexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
            if selection != model.selected, let selectedIndex { table.scrollRowToVisible(selectedIndex) }
            selection = model.selected
            syncing = false
        }
        func clearImages() { for cell in cells.allObjects { cell.clear() } }
        func numberOfRows(in tableView: NSTableView) -> Int { photos.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard photos.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("thumbnail")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ThumbnailCell ?? ThumbnailCell()
            cell.identifier = identifier
            cells.add(cell)
            cell.configure(url: photos[row], index: row, session: model.sessionID, store: model.images)
            return cell
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !model.busy }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, !model.busy, let table else { return }
            model.selected = photos.indices.contains(table.selectedRow) ? photos[table.selectedRow] : nil
            selection = model.selected
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard !model.busy, photos.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString("\(model.sessionID.uuidString)|\(photos[row].absoluteString)", forType: NativePhotoList.dragType)
            return item
        }
        private func sourceIndex(_ token: String) -> Int? {
            guard !model.busy, token.hasPrefix(model.sessionID.uuidString + "|"),
                  let url = URL(string: String(token.dropFirst(model.sessionID.uuidString.count + 1))), url.isFileURL else { return nil }
            return model.photos.firstIndex(of: url)
        }
        func applyDrop(_ token: String, at row: Int) -> Bool {
            guard let source = sourceIndex(token), (0...model.photos.count).contains(row) else { return false }
            model.move(from: IndexSet(integer: source), to: row)
            return true
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let source = info.draggingSource as? NSTableView, source === tableView,
                  let token = info.draggingPasteboard.string(forType: NativePhotoList.dragType), sourceIndex(token) != nil else { return [] }
            tableView.setDropRow(max(0, min(row, photos.count)), dropOperation: .above)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let source = info.draggingSource as? NSTableView, source === tableView,
                  let token = info.draggingPasteboard.string(forType: NativePhotoList.dragType) else { return false }
            return applyDrop(token, at: max(0, min(row, photos.count)))
        }
    }
}

@MainActor
private final class ThumbnailCell: NSTableCellView {
    private let thumbnail = NSImageView()
    private let number = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private var representedURL: URL?
    private var representedSession: UUID?
    private var loadTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.textColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        for view in [thumbnail, number, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 92), thumbnail.heightAnchor.constraint(equalToConstant: 72),
            number.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 8),
            number.centerYAnchor.constraint(equalTo: centerYAnchor), number.widthAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), name.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view") }
    deinit { loadTask?.cancel() }
    func configure(url: URL, index: Int, session: UUID, store: PreviewImageStore) {
        number.stringValue = String(format: "%02d", index + 1)
        name.stringValue = url.lastPathComponent
        setAccessibilityLabel("Frame \(index + 1), \(url.lastPathComponent)")
        guard representedURL != url || representedSession != session else { return }
        clear()
        representedURL = url
        representedSession = session
        thumbnail.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        loadTask = Task { [weak self] in
            let loaded = await store.image(for: url, maximum: 160)
            guard !Task.isCancelled, let self, self.representedURL == url, self.representedSession == session, let loaded else { return }
            self.thumbnail.image = NSImage(cgImage: loaded, size: NSSize(width: CGFloat(loaded.width), height: CGFloat(loaded.height)))
        }
    }
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        thumbnail.image = nil
        representedURL = nil
        representedSession = nil
    }
}
