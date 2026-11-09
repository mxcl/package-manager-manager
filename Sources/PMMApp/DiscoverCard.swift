import AppKit

func discoverTextHeight(_ text: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    ceil((text as NSString).boundingRect(
        with: NSSize(width: max(1, width - 6), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]
    ).height) + 6
}

@MainActor
private final class DiscoverButton: NSButton {
    var invoke: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        invoke = action
        target = self
        self.action = #selector(performAction)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 11, weight: .semibold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { invoke?() }
}

@MainActor
final class DiscoverHeading: NSView {
    override var isFlipped: Bool { true }
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private var link: NSButton?
    private var large = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(title)
        addSubview(subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        title.setAccessibilityRoleDescription("heading")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String?, link: URL?, large: Bool) {
        self.title.stringValue = title
        self.title.font = .systemFont(ofSize: large ? 28 : 17, weight: .bold)
        self.subtitle.stringValue = subtitle ?? ""
        self.large = large
        self.link?.removeFromSuperview()
        self.link = nil
        if let link {
            let button = DiscoverButton(title == "New & Trending" ? "See all" : "View all") { NSWorkspace.shared.open(link) }
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
            addSubview(button)
            self.link = button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: large ? 36 : 28, y: large ? 24 : 0, width: max(0, bounds.width - 150), height: large ? 36 : 26)
        subtitle.frame = NSRect(x: 28, y: 27, width: max(0, bounds.width - 56), height: 34)
        link?.frame = NSRect(x: bounds.width - 100, y: 0, width: 72, height: 26)
    }
}

/// One native view reused for feed cards. Artwork requests belong to the current
/// configuration and are cancelled when a collection item is recycled.
@MainActor
final class DiscoverCard: NSView {
    override var isFlipped: Bool { true }
    private enum Kind { case package, editorial, sponsor, blog, status }
    private var kind: Kind = .status
    private var labels: [NSTextField] = []
    private var icons: [Int: NSImageView] = [:]
    private var primary: DiscoverButton?
    private var details: DiscoverButton?
    private var install: DiscoverButton?
    private var retry: DiscoverButton?
    private var spinner = NSProgressIndicator()
    private var image: NSImage?
    private var imageTask: Task<Void, Never>?
    private var imageToken = UUID()
    private var gradientColors: [NSColor] = []
    private static let ditherColor = discoverDitherImage.map {
        NSColor(patternImage: NSImage(cgImage: $0, size: NSSize(width: 32, height: 32)))
    }
    private var foreground: NSColor = .labelColor
    private var hasInstallURL = false
    private var imageFailed = false
    private var fallbackSymbol = "photo"
    private let sponsorSymbol = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        sponsorSymbol.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        sponsorSymbol.contentTintColor = .white
        sponsorSymbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        sponsorSymbol.imageScaling = .scaleProportionallyUpOrDown
        sponsorSymbol.isHidden = true
        addSubview(sponsorSymbol)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        imageTask?.cancel()
        imageTask = nil
        imageToken = UUID()
        image = nil
        imageFailed = false
        sponsorSymbol.isHidden = true
        for label in labels { label.removeFromSuperview() }
        labels = []
        icons.values.forEach { $0.removeFromSuperview() }
        icons = [:]
        for button in [primary, details, install, retry] { button?.removeFromSuperview() }
        primary = nil; details = nil; install = nil; retry = nil
        spinner.stopAnimation(nil)
        gradientColors = []
        foreground = .labelColor
        needsDisplay = true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil, lines: Int = 0) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color ?? foreground
        label.maximumNumberOfLines = lines
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.usesSingleLineMode = false
        addSubview(label)
        labels.append(label)
    }

    private func symbolLabel(_ text: String, symbol: String, color: NSColor) {
        let index = labels.count
        label(text, size: 10, color: color)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.setAccessibilityElement(false)
        addSubview(icon)
        icons[index] = icon
    }

    private func action(_ accessibilityLabel: String, _ invoke: @escaping () -> Void) {
        let button = DiscoverButton("", action: invoke)
        button.isBordered = false
        button.setAccessibilityLabel(accessibilityLabel)
        addSubview(button)
        primary = button
    }

    func package(_ package: DiscoverFeedPackage, eyebrow: String?, installed: Bool, open: @escaping () -> Void, install: @escaping () -> Void) {
        reset()
        kind = .package
        if let eyebrow { label(eyebrow, size: 9, weight: .bold, color: .controlAccentColor) }
        label(package.displayName, size: 13, weight: .semibold)
        label(package.agentSummary, size: 11, color: .secondaryLabelColor)
        if let ecosystem = package.ecosystem { symbolLabel(ecosystem, symbol: "shippingbox", color: .secondaryLabelColor) }
        if let category = mainWindowCategoryTitle(package.category) { symbolLabel(category, symbol: "tag", color: .controlAccentColor) }
        action(package.displayName + ", " + package.agentSummary, open)
        let details = DiscoverButton("Details", action: open)
        details.isBordered = false
        addSubview(details)
        self.details = details
        let installButton = DiscoverButton("Install", action: install)
        installButton.controlSize = .small
        installButton.bezelColor = .controlAccentColor
        addSubview(installButton)
        self.install = installButton
        hasInstallURL = package.installURL != nil
        setInstalled(installed)
        needsLayout = true
    }

    func setInstalled(_ installed: Bool) {
        install?.title = installed ? "Installed" : "Install"
        install?.isEnabled = !installed
        install?.isHidden = !installed && !hasInstallURL
    }

    func editorial(_ editorial: DiscoverFeedContent, read: @escaping () -> Void) {
        reset()
        kind = .editorial
        let colors = editorial.artwork?.boxColors
        foreground = NSColor(discoverHex: colors?.foreground ?? "#FFFFFF")
        gradientColors = [NSColor(discoverHex: colors?.backgroundStart ?? "#1F1638"), NSColor(discoverHex: colors?.backgroundEnd ?? "#481488")]
        label("EDITORIAL", size: 11, weight: .bold, color: foreground.withAlphaComponent(0.7))
        label(editorial.title ?? "Featured", size: 28, weight: .bold, lines: 4)
        if let deck = editorial.deck { label(deck, size: 15, color: foreground.withAlphaComponent(0.78), lines: 4) }
        action("Read " + (editorial.title ?? "featured article"), read)
        primary?.setAccessibilityHelp("Opens the full editorial")
        if let url = editorial.artworkURL { loadImage(url) }
        needsLayout = true
    }

    func sponsor() {
        reset()
        kind = .sponsor
        foreground = .white
        gradientColors = [NSColor(discoverHex: "#59299E"), NSColor(discoverHex: "#FA7040"), NSColor(discoverHex: "#CD422E"), NSColor(discoverHex: "#0D0F1A")]
        label(" ", size: 34, weight: .semibold)
        sponsorSymbol.isHidden = false
        label("Command line security is broken. We fix it at the packaging layer.", size: 24, weight: .bold)
        label("Raising the bar on macOS command line security. From the creator of Homebrew.", size: 13, weight: .medium, color: .white.withAlphaComponent(0.78))
        label("Learn more", size: 13, weight: .semibold)
        label("SPONSORED", size: 8, weight: .bold, color: .white.withAlphaComponent(0.7))
        action("Command line security is broken. Learn more. Sponsored.") {
            NSWorkspace.shared.open(URL(string: "https://automicvault.com?utm_source=pmm")!)
        }
        needsLayout = true
    }

    func blog(_ post: DashboardBlogEntry) {
        reset()
        kind = .blog
        label(post.title, size: 14, weight: .semibold, lines: 2)
        label(post.subtitle, size: 11, color: .secondaryLabelColor, lines: 2)
        label(post.publishedAt, size: 10, color: .tertiaryLabelColor)
        action(post.title + ", " + post.subtitle) { NSWorkspace.shared.open(post.url) }
        fallbackSymbol = post.systemImage
        loadImage(post.imageURL)
        needsLayout = true
    }

    func status(_ text: String, loading: Bool, retry: (() -> Void)?) {
        reset()
        kind = .status
        label(text, size: 13, color: .secondaryLabelColor)
        labels.first?.alignment = .center
        if loading { spinner.startAnimation(nil) }
        if let retry {
            let button = DiscoverButton("Retry", action: retry)
            addSubview(button)
            self.retry = button
        }
        needsLayout = true
    }

    private func loadImage(_ url: URL) {
        let token = imageToken
        spinner.startAnimation(nil)
        imageTask = Task { [weak self] in
            do {
                try await DiscoverImageLoader.shared.load(url) { [weak self] payload in
                    guard let self, self.imageToken == token, !Task.isCancelled else { return }
                    self.image = payload.image
                    self.spinner.stopAnimation(nil)
                    self.needsDisplay = true
                }
            } catch {
                guard let self, self.imageToken == token, !Task.isCancelled else { return }
                self.spinner.stopAnimation(nil)
                self.imageFailed = self.image == nil
                self.needsDisplay = true
            }
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = kind == .editorial ? 36 : kind == .blog || kind == .sponsor ? 16 : 18
        let width = max(1, min(kind == .editorial ? 320 : .greatestFiniteMagnitude, bounds.width - inset * 2))
        var y: CGFloat = kind == .blog ? 156 : inset
        var heights = labels.map { label in
            min(label.maximumNumberOfLines > 0 ? CGFloat(label.maximumNumberOfLines) * ceil((label.font?.pointSize ?? 13) * 1.3) : .greatestFiniteMagnitude,
                discoverTextHeight(label.stringValue, width: width, size: label.font?.pointSize ?? 13,
                                   weight: (label.font?.fontDescriptor.symbolicTraits.contains(.bold) == true) ? .bold : .regular))
        }
        if kind == .sponsor {
            y = max(16, bounds.height - heights.reduce(0, +) - CGFloat(max(0, labels.count - 1)) * 12 - 16)
        }
        if kind == .status {
            y = bounds.midY
            heights = [36]
        }
        for (index, label) in labels.enumerated() {
            let iconInset: CGFloat = icons[index] == nil ? 0 : 16
            label.frame = NSRect(x: inset + iconInset, y: y, width: width - iconInset, height: heights[index])
            icons[index]?.frame = NSRect(x: inset, y: y + 2, width: 12, height: 12)
            y += heights[index] + (kind == .editorial ? 14 : kind == .sponsor ? 12 : 7)
        }
        if kind == .sponsor, let first = labels.first {
            sponsorSymbol.frame = NSRect(x: first.frame.minX, y: first.frame.minY, width: 38, height: 38)
            if labels.count == 5 {
                labels[3].frame.size = NSSize(width: 118, height: 32)
                labels[3].alignment = .center
                labels[3].textColor = .black.withAlphaComponent(0.86)
                labels[4].alignment = .right
            }
        }
        primary?.frame = bounds
        if kind == .package {
            primary?.frame.size.height = max(0, bounds.height - 46)
            details?.frame = NSRect(x: 14, y: bounds.height - 40, width: 50, height: 24)
            install?.frame = NSRect(x: bounds.width - 96, y: bounds.height - 40, width: 78, height: 24)
        }
        spinner.frame = NSRect(x: kind == .editorial ? bounds.width - 44 : bounds.midX - 10, y: kind == .blog ? 60 : bounds.midY - 32, width: 20, height: 20)
        retry?.frame = NSRect(x: bounds.midX - 50, y: bounds.midY + 38, width: 100, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: bounds, xRadius: kind == .editorial ? 22 : 18, yRadius: kind == .editorial ? 22 : 18)
        path.addClip()
        if gradientColors.isEmpty {
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
        } else { NSGradient(colors: gradientColors)?.draw(in: bounds, angle: 55) }
        if let image {
            let rect = kind == .blog ? NSRect(x: 0, y: 0, width: bounds.width, height: 140) : bounds
            let scale = max(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
            let crop = NSRect(x: (image.size.width - rect.width / scale) / 2, y: (image.size.height - rect.height / scale) / 2, width: rect.width / scale, height: rect.height / scale)
            image.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if imageFailed {
            let symbol = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)
            symbol?.draw(in: NSRect(x: bounds.midX - 16, y: kind == .blog ? 54 : bounds.midY - 16, width: 32, height: 32))
        }
        if kind == .editorial, let color = gradientColors.first {
            NSGradient(colors: [color.withAlphaComponent(0.98), color.withAlphaComponent(0.7), color.withAlphaComponent(0)])?.draw(in: bounds, angle: 0)
        }
        if kind == .sponsor, let dither = Self.ditherColor {
            // Match the original card's tiled noise to break up gradient banding.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(2 / 255)
            NSGraphicsContext.current?.imageInterpolation = .none
            dither.setFill()
            bounds.fill(using: .sourceOver)
            NSGraphicsContext.restoreGraphicsState()
        }
        if kind == .sponsor, labels.count == 5 {
            let pill = labels[3].frame.offsetBy(dx: 0, dy: -6)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension NSColor {
    convenience init(discoverHex value: String) {
        let integer = UInt64(value.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((integer >> 16) & 255) / 255, green: CGFloat((integer >> 8) & 255) / 255, blue: CGFloat(integer & 255) / 255, alpha: 1)
    }
}
