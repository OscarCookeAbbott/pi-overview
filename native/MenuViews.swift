import Cocoa

func statusImage(_ state: String?, size: CGFloat = 14) -> NSImage? {
    let image = NSImage(systemSymbolName: statusSymbolName(state), accessibilityDescription: state)
    image?.size = NSSize(width: size, height: size)
    image?.isTemplate = true
    return image
}

func applyStatusIcon(_ item: NSMenuItem, state: String?) {
    item.image = statusImage(state)
    if item.image == nil { item.title = "\(itemSymbol(state)) \(item.title)" }
}

func menubarAttributedTitle(_ instances: [InstanceInfo], phase: Int = 0) -> NSAttributedString {
    let font = NSFont.menuBarFont(ofSize: 0)
    let title = NSMutableAttributedString(string: menubarTitle(instances, phase: phase), attributes: [.font: font])
    for state in ["running", "complete", "failed", "pending"] {
        let range = (title.string as NSString).range(of: itemSymbol(state, phase: phase))
        guard range.location != NSNotFound, let image = statusImage(state, size: font.pointSize) else { continue }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - font.pointSize) / 2, width: font.pointSize, height: font.pointSize)
        title.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
    }
    return title
}

/// Read-only content inside a native submenu; long bodies scroll without flooding the menu.
final class ContributionCard: NSView {
    let titleLabel: NSTextField
    let subtitleLabel: NSTextField
    let textView = NSTextView()
    let scrollView = NSScrollView()
    override var isFlipped: Bool { true }

    init(_ item: OverviewItem) {
        let body = item.body ?? item.detail ?? ""
        let font = item.kind == "job" ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12)
        let measured = (body as NSString).boundingRect(with: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        let bodyHeight = body.isEmpty ? 0 : min(200, max(48, ceil(measured) + 16))
        titleLabel = NSTextField(wrappingLabelWithString: item.title)
        subtitleLabel = NSTextField(labelWithString: item.subtitle ?? item.state?.capitalized ?? "")
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 68 + bodyHeight))
        identifier = NSUserInterfaceItemIdentifier("overview.detail-card")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.frame = NSRect(x: 12, y: 10, width: 336, height: 34)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 12, y: 46, width: 336, height: 16)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        if !body.isEmpty {
            scrollView.frame = NSRect(x: 10, y: 66, width: 340, height: bodyHeight)
            scrollView.drawsBackground = false
            scrollView.contentView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            textView.frame = NSRect(x: 0, y: 0, width: 324, height: bodyHeight)
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.font = font
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.minSize = NSSize(width: 0, height: bodyHeight)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: 324, height: CGFloat.greatestFiniteMagnitude)
            textView.string = body
            textView.sizeToFit()
            textView.setAccessibilityLabel("\(item.kind ?? "Item") details")
            scrollView.documentView = textView
            addSubview(scrollView)
        }
    }

    required init?(coder: NSCoder) { return nil }
}
