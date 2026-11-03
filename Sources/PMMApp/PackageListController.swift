import AppKit
import Combine
import PMMCore
import SwiftUI

/// A small bridge lets the existing detail/sheet composition survive the browser migration.
struct NativePackageList: NSViewControllerRepresentable {
    let model: MainWindowModel
    func makeNSViewController(context: Context) -> PackageListController { PackageListController(model: model) }
    func updateNSViewController(_ controller: PackageListController, context: Context) {}
}

@MainActor
final class PackageListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: MainWindowModel
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let options = NSPopUpButton(frame: .zero, pullsDown: true)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let emptyState = NSStackView()
    private var observation: AnyCancellable?
    private var refreshScheduled = false
    private var applyingSelection = false
    private var packages: [ManagedPackage] = []
    private var section: MainWindowSidebarSelection?
    private var rowContext: PackageRowContext?
    private var setup: NSHostingView<PackageListSetupView>!

    init(model: MainWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        options.setAccessibilityLabel("Filter and sort packages")
        options.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [titleLabel, spinner, options])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.heightAnchor.constraint(equalToConstant: 42).isActive = true

        table.addTableColumn(NSTableColumn(identifier: .init("package")))
        table.headerView = nil
        table.rowHeight = 70
        table.intercellSpacing = .zero
        table.style = .plain
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("package-list")
        table.setAccessibilityLabel("Packages")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        setup = NSHostingView(rootView: PackageListSetupView(model: model))
        setup.sizingOptions = [.intrinsicContentSize]
        let stack = NSStackView(views: [header, setup, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        pin(stack, to: view)
        for child in [header, setup!, scroll] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        retry.target = self
        retry.action = #selector(retryHost)
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        emptyState.orientation = .vertical
        emptyState.spacing = 10
        emptyState.addArrangedSubview(message)
        emptyState.addArrangedSubview(retry)
        view.addSubview(emptyState)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 55),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -24),
        ])
        observation = Publishers.MergeMany([
            uiChange(model.$packageListRevision), uiChange(model.$remoteHostStates),
            uiChange(model.$selectedSection), uiChange(model.$selectedRemoteHostID), uiChange(model.$selectedRemoteSection),
            uiChange(model.$selectedPackageIDs), uiChange(model.$categorySortOrder),
            uiChange(model.$showsCategoryCLIs), uiChange(model.$showsCategoryGUIs),
            uiChange(model.$searchIsLoading), uiChange(model.$isReloading), uiChange(model.$loadingManagers),
            uiChange(model.$discoverPackageIDToScrollIntoView), uiChange(model.$setupOffer),
            uiChange(model.$setupDetectingManager), uiChange(model.$installingPackageName),
        ]).sink { [weak self] in self?.scheduleRefresh() }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // @Published emits before mutation; reconcile once after the transaction completes.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        let next = model.displayedPackages
        let nextSection = model.sidebarSelection
        let context = PackageRowContext(model: model)
        titleLabel.stringValue = model.displayedSectionTitle
        let loading = model.displayedPackagesAreLoading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        options.isHidden = model.activeSidebarSection?.categoryIdentifier == nil
        if !options.isHidden { updateOptions() }
        let hasSetup = model.activeSidebarSection.map {
            model.setupOffer(for: $0) != nil || model.isDetectingSetupOffer(for: $0)
        } ?? false
        setup.isHidden = !hasSetup
        emptyState.isHidden = !next.isEmpty || hasSetup
        message.stringValue = loading ? "Loading packages…" : (model.displayedPackagesError ?? "No packages")
        retry.isHidden = model.displayedPackagesError == nil || model.selectedRemoteHostID == nil
        applyingSelection = true
        table.allowsMultipleSelection = model.showsUpdateAllOutdatedPackages
        if next != packages || rowContext != context || section != nextSection {
            let old = packages
            let oldIDs = old.map(\.id)
            let newIDs = next.map(\.id)
            let visibleRow = table.row(at: scroll.contentView.bounds.origin)
            let anchorID = old.indices.contains(visibleRow) ? old[visibleRow].id : nil
            let offset = scroll.contentView.bounds.origin.y - CGFloat(max(visibleRow, 0)) * table.rowHeight
            packages = next
            let changedSection = section != nextSection
            let changedContext = rowContext != context
            section = nextSection
            rowContext = context
            if changedSection {
                table.reloadData()
                scroll.contentView.scroll(to: .zero)
            } else if oldIDs == newIDs {
                let changed = IndexSet(next.indices.filter { changedContext || old[$0] != next[$0] })
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            } else {
                let difference = newIDs.difference(from: oldIDs)
                var removed = IndexSet(), inserted = IndexSet()
                for change in difference {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                table.beginUpdates()
                table.removeRows(at: removed, withAnimation: [])
                table.insertRows(at: inserted, withAnimation: [])
                table.endUpdates()
                // Surviving rows may also have new metadata or a different context.
                let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let changed = IndexSet(next.indices.filter { !inserted.contains($0) && (changedContext || oldByID[next[$0].id] != next[$0]) })
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                if let anchorID, let row = newIDs.firstIndex(of: anchorID) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, CGFloat(row) * table.rowHeight + offset)))
                }
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let selected = IndexSet(packages.indices.filter { model.selectedPackageIDs.contains(packages[$0].id) })
        if table.selectedRowIndexes != selected {
            table.selectRowIndexes(selected, byExtendingSelection: false)
            if selected.count == 1, let row = selected.first { table.scrollRowToVisible(row) }
        }
        applyingSelection = false
        if let id = model.discoverPackageIDToScrollIntoView, let row = packages.firstIndex(where: { $0.id == id }) {
            table.scrollRowToVisible(row)
            model.consumeDiscoverPackageScrollRequest()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { packages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("package-cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NativePackageCell ?? NativePackageCell()
        cell.identifier = id
        cell.configure(packages[row], context: rowContext!)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PackageSelectionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let ids = Set(table.selectedRowIndexes.compactMap { packages.indices.contains($0) ? packages[$0].id : nil })
        if ids != model.selectedPackageIDs { model.selectPackages(ids) }
    }

    private func updateOptions() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Options", action: nil, keyEquivalent: "")
        for (title, tag, checked) in [("CLIs", 0, model.showsCategoryCLIs), ("GUIs", 1, model.showsCategoryGUIs)] {
            let item = menu.addItem(withTitle: title, action: #selector(changeOption(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; item.state = checked ? .on : .off
        }
        menu.addItem(.separator())
        for (index, sort) in CategorySortOrder.allCases.enumerated() {
            let item = menu.addItem(withTitle: sort.rawValue, action: #selector(changeOption(_:)), keyEquivalent: "")
            item.target = self; item.tag = index + 2; item.state = model.categorySortOrder == sort ? .on : .off
        }
        options.menu = menu
    }
    @objc private func changeOption(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: model.showsCategoryCLIs.toggle()
        case 1: model.showsCategoryGUIs.toggle()
        default: model.categorySortOrder = CategorySortOrder.allCases[sender.tag - 2]
        }
    }
    @objc private func retryHost() { if let id = model.selectedRemoteHostID { model.refreshRemoteHost(id) } }
}

struct PackageRowContext: Equatable {
    let section: MainWindowSection?
    let showsInstalled: Bool
    let showsManager: Bool
    @MainActor init(model: MainWindowModel) {
        section = model.selectedRemoteSection == .outdated ? .outdated : model.activeSidebarSection
        showsInstalled = section == .search
        showsManager = section == .search || model.isRemoteSelection || section == .outdated || (section?.packageManagers.count ?? 0) > 1
    }
}

@MainActor
private final class NativePackageCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let version = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let mark = NSImageView()
    private let secondaryMark = NSImageView()
    private let sourceBadge = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        version.font = .systemFont(ofSize: 12, weight: .medium)
        version.textColor = .secondaryLabelColor
        version.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.cell?.wraps = true
        subtitle.cell?.isScrollable = false
        subtitle.setContentCompressionResistancePriority(.required, for: .vertical)
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        mark.imageScaling = .scaleProportionallyDown
        mark.widthAnchor.constraint(equalToConstant: 15).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 15).isActive = true
        secondaryMark.widthAnchor.constraint(equalToConstant: 15).isActive = true
        secondaryMark.heightAnchor.constraint(equalToConstant: 15).isActive = true
        secondaryMark.imageScaling = .scaleProportionallyDown
        sourceBadge.font = .systemFont(ofSize: 8, weight: .heavy)
        sourceBadge.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [name, mark, secondaryMark, sourceBadge, badge, spacer, version])
        heading.distribution = .fill
        heading.spacing = 4
        let stack = NSStackView(views: [heading, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        textField = name
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        let width = max(0, bounds.width - 20)
        if subtitle.preferredMaxLayoutWidth != width { subtitle.preferredMaxLayoutWidth = width }
        super.layout()
    }
    func configure(_ package: ManagedPackage, context: PackageRowContext) {
        name.stringValue = package.displayName
        version.stringValue = mainWindowVersionText(package, section: context.section)
        version.isHidden = version.stringValue.isEmpty
        subtitle.stringValue = mainWindowPackageSubtitle(package, showsManager: context.showsManager) ?? ""
        let section = mainWindowManagerSection(for: package)
        mark.image = nativeSidebarImage(section)
        secondaryMark.image = nil
        sourceBadge.stringValue = package.manager == .mise ? "MISE" : ""
        if section == .apps {
            switch mainWindowMacAppMark(for: package.appProvenance) {
            case .asset(let name): mark.image = NSImage(named: name)
            case .paired(let asset, let system):
                mark.image = NSImage(named: asset)
                secondaryMark.image = NSImage(systemSymbolName: system, accessibilityDescription: nil)
            case .system(let name): mark.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            case .text(let title): mark.image = nil; sourceBadge.stringValue = title
            }
        }
        let color: NSColor
        switch section {
        case .apps: color = .systemTeal
        case .homebrew: color = .systemOrange
        case .javascript: color = .systemYellow
        case .python: color = .systemBlue
        case .rust: color = .systemRed
        case .skills: color = .systemPurple
        default: color = .secondaryLabelColor
        }
        mark.contentTintColor = secondaryMark.image == nil ? color : .systemOrange
        secondaryMark.contentTintColor = .systemTeal
        sourceBadge.textColor = color
        mark.isHidden = mark.image == nil
        secondaryMark.isHidden = secondaryMark.image == nil
        sourceBadge.isHidden = sourceBadge.stringValue.isEmpty
        mark.toolTip = package.sourceTitle
        badge.stringValue = context.showsInstalled && package.installedVersion != nil ? "Installed"
            : package.isOutdated && !context.showsManager ? "Outdated" : ""
        badge.textColor = badge.stringValue == "Installed" ? .systemGreen : .systemOrange
        badge.isHidden = badge.stringValue.isEmpty
        setAccessibilityLabel([package.displayName, package.sourceTitle, version.stringValue, badge.stringValue, subtitle.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        toolTip = subtitle.stringValue
    }
}

struct PackageListSetupView: View {
    @ObservedObject var model: MainWindowModel
    var body: some View {
        if let section = model.activeSidebarSection {
            if let offer = model.setupOffer(for: section) {
                ManagerSetupCard(offer: offer, isInstalling: model.isInstallingHelper,
                                 canInstall: model.canInstallHelper, install: { model.installHelper(offer.id) },
                                 dismiss: { model.dismissHelper(offer.id) })
            } else if model.isDetectingSetupOffer(for: section) { ManagerSetupDetectionCard() }
        }
    }
}

@MainActor
func pin(_ child: NSView, to parent: NSView) {
    parent.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}

@MainActor
func nativeSidebarImage(_ section: MainWindowSection) -> NSImage? {
    if let name = section.sidebarImage, let image = NSImage(named: name) {
        let copy = image.copy() as! NSImage
        copy.isTemplate = true
        return copy
    }
    return NSImage(systemSymbolName: section.systemImage, accessibilityDescription: section.title)
}

/// Native controllers subscribe to their own inputs, not command-output or dossier changes.
func uiChange<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
    publisher.map { _ in () }.eraseToAnyPublisher()
}

/// Match the former inset selection without giving up native table selection/keyboard behavior.
@MainActor
private final class PackageSelectionRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(isEmphasized ? 0.22 : 0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 10, yRadius: 10).fill()
    }
}
