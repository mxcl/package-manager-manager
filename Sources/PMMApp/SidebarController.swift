import AppKit
import Combine
import PMMCore

struct SidebarEntry: Equatable {
    let id: String
    let title: String
    var selection: MainWindowSidebarSelection?
    var count: Int?
    var loading = false
    var error: String?
    var children: [SidebarEntry] = []
}

@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let model: MainWindowModel
    let outline = NSOutlineView()
    let search = NSSearchField()
    private var nodes: [Node] = []
    private var entries: [SidebarEntry] = []
    private var applyingSelection = false
    private var lastSelection: MainWindowSidebarSelection?
    private var observation: AnyCancellable?
    private var refreshScheduled = false
    private let hostName = MainWindowModel.localSidebarHostName

    private final class Node: NSObject {
        var entry: SidebarEntry
        var children: [Node] = []
        init(_ entry: SidebarEntry) { self.entry = entry; self.children = entry.children.map(Node.init) }
    }
    init(model: MainWindowModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        view = background
        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityIdentifier("package-search")
        search.setAccessibilityLabel("Search packages")
        let column = NSTableColumn(identifier: .init("sidebar"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 30
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityIdentifier("package-sidebar")
        outline.setAccessibilityLabel("Package sections")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view.addSubview(search)
        view.addSubview(scroll)
        search.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        observation = Publishers.MergeMany([
            uiChange(model.$packageListRevision), uiChange(model.$remoteHosts), uiChange(model.$remoteHostStates),
            uiChange(model.$selectedSection), uiChange(model.$selectedRemoteHostID), uiChange(model.$selectedRemoteSection),
            uiChange(model.$searchText), uiChange(model.$searchIsLoading), uiChange(model.$isReloading),
            uiChange(model.$loadingManagers), uiChange(model.$showsCategoryCLIs), uiChange(model.$showsCategoryGUIs),
        ]).sink { [weak self] in self?.scheduleRefresh() }
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) { model.searchText = search.stringValue }
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }
    func refresh() {
        if search.stringValue != model.searchText { search.stringValue = model.searchText }
        let next = makeEntries()
        applyingSelection = true
        if next != entries {
            let expanded = Set(nodes.filter { outline.isItemExpanded($0) }.map { $0.entry.id })
            let existing = Set(nodes.map { $0.entry.id })
            let oldNodes = Dictionary(nodes.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
            nodes = next.map { entry in
                let node = oldNodes[entry.id] ?? Node(entry)
                let children = Dictionary(node.children.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
                node.children = entry.children.map { child in
                    let result = children[child.id] ?? Node(child)
                    result.entry = child
                    return result
                }
                node.entry = entry
                return node
            }
            entries = next
            outline.reloadData()
            for node in nodes where expanded.contains(node.entry.id) || !existing.contains(node.entry.id) {
                outline.expandItem(node)
            }
        }
        // A deep link or search restoration can select a row inside a collapsed group.
        if lastSelection != model.sidebarSelection {
            for node in nodes where node.children.contains(where: { $0.entry.selection == model.sidebarSelection }) {
                outline.expandItem(node)
            }
            lastSelection = model.sidebarSelection
        }
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? Node)?.entry.selection == model.sidebarSelection }
        if let row {
            if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else { outline.deselectAll(nil) }
        applyingSelection = false
    }

    private func makeEntries() -> [SidebarEntry] {
        func local(_ section: MainWindowSection) -> SidebarEntry {
            SidebarEntry(id: section.id, title: section.title, selection: .local(section),
                         count: model.count(for: section), loading: model.isLoadingCount(for: section))
        }
        var entries: [SidebarEntry] = []
        if model.hasSearchText { entries.append(local(.search)) }
        if model.hasMultipleHosts {
            entries.append(local(.home))
            entries.append(SidebarEntry(id: "local-host", title: hostName,
                                       children: [local(.installed)] + model.visibleManagerSections.map(local) + [local(.outdated)]))
        } else {
            entries += MainWindowSection.librarySections.map(local)
            if !model.visibleManagerSections.isEmpty {
                entries.append(SidebarEntry(id: "ecosystems", title: "Ecosystems", children: model.visibleManagerSections.map(local)))
            }
        }
        for host in model.remoteHosts {
            entries.append(SidebarEntry(id: host.id.uuidString, title: host.displayName, error: model.error(for: host.id), children:
                RemoteHostSection.allCases.map {
                    SidebarEntry(id: "\(host.id)-\($0.rawValue)", title: $0.title,
                                 selection: .remote(hostID: host.id, section: $0), count: model.count(for: $0, on: host.id), loading: model.isLoading(host.id))
                }))
        }
        if !model.visibleCategorySections.isEmpty {
            entries.append(SidebarEntry(id: "categories", title: "Categories", children: model.visibleCategorySections.map(local)))
        }
        return entries
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? nodes.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? nodes[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as! Node).entry.selection == nil }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! Node).entry.selection != nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let entry = (item as! Node).entry
        let identifier = NSUserInterfaceItemIdentifier("sidebar-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NativeSidebarCell ?? NativeSidebarCell()
        cell.identifier = identifier
        cell.configure(entry)
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? Node,
              let selection = node.entry.selection, selection != model.sidebarSelection else { return }
        switch selection {
        case .local(let section): model.selectSection(section)
        case .remote(let id, let section): model.selectRemoteHost(id, section: section)
        }
        model.refreshSetupOffers()
    }
}

@MainActor
private final class NativeSidebarCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = NSStackView(views: [icon, title, count, spinner])
        stack.distribution = .fill
        stack.spacing = 7
        pin(stack, to: self)
        textField = title
        imageView = icon
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ entry: SidebarEntry) {
        title.stringValue = entry.title
        title.font = .systemFont(ofSize: entry.selection == nil ? 11 : 13, weight: entry.selection == nil ? .semibold : .regular)
        title.textColor = entry.selection == nil ? .secondaryLabelColor : .labelColor
        switch entry.selection {
        case .local(let section): icon.image = nativeSidebarImage(section)
        case .remote(_, let section): icon.image = NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil)
        case nil: icon.image = entry.error == nil ? nil : NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Connection error")
        }
        icon.isHidden = icon.image == nil
        count.stringValue = entry.count.map { $0 > 0 ? String($0) : "" } ?? ""
        count.isHidden = entry.loading || count.stringValue.isEmpty
        spinner.isHidden = !entry.loading
        if entry.loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        toolTip = entry.error
        setAccessibilityLabel([entry.title, entry.loading ? "Loading" : count.stringValue, entry.error ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
