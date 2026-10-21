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

let overviewMenuWidth: CGFloat = 420

func fitMenuViews(_ menu: NSMenu) {
    let width = menu.size.width
    for item in menu.items {
        guard let view = item.view, view.autoresizingMask.contains(.width) else { continue }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }
}

/// The first level of agent information belongs in the main menu, not behind a hover.
final class AgentCard: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let metadataLabel = NSTextField(labelWithString: "")
    let taskLabel = NSTextField(labelWithString: "")
    let activityLabel = NSTextField(wrappingLabelWithString: "")
    let statusView = NSImageView()
    override var isFlipped: Bool { true }

    init(_ info: InstanceInfo) {
        super.init(frame: NSRect(x: 0, y: 0, width: overviewMenuWidth, height: 97))
        identifier = NSUserInterfaceItemIdentifier("overview.agent-card")
        autoresizingMask = [.width]
        statusView.frame = NSRect(x: 16, y: 8, width: 14, height: 14)
        statusView.contentTintColor = .labelColor
        addSubview(statusView)
        titleLabel.frame = NSRect(x: 36, y: 6, width: frame.width - 52, height: 18)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        metadataLabel.frame = NSRect(x: 36, y: 26, width: frame.width - 52, height: 14)
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingMiddle
        taskLabel.frame = NSRect(x: 36, y: 44, width: frame.width - 52, height: 16)
        taskLabel.font = .systemFont(ofSize: 11)
        activityLabel.frame = NSRect(x: 36, y: 63, width: frame.width - 52, height: 28)
        activityLabel.font = .systemFont(ofSize: 11)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.maximumNumberOfLines = 2
        for label in [titleLabel, metadataLabel, taskLabel, activityLabel] {
            label.autoresizingMask = [.width]
            addSubview(label)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        taskLabel.lineBreakMode = .byTruncatingTail
        configure(info)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(_ info: InstanceInfo) {
        let status = displayText(info.isLive() || info.closed ? info.displayStatus : "Disconnected", limit: 60)
        titleLabel.stringValue = displayText(info.sessionName ?? info.projectName, limit: 120)
        titleLabel.toolTip = titleLabel.stringValue
        statusView.image = statusImage(agentState(info), size: 14)
        statusView.setAccessibilityLabel(status)
        let closed = info.closed && !["Closed", "Exited"].contains(info.displayStatus) ? " · Closed" : ""
        let directory = (info.cwd as NSString).abbreviatingWithTildeInPath
        metadataLabel.stringValue = "\(status)\(closed) · \(displayText(directory, limit: 180))"
        metadataLabel.toolTip = "\(status)\n\(displayText(info.cwd, limit: 1024))\nPID \(info.pid) · \(info.id.prefix(8))"
        let task = activeTaskTitle(info)
        taskLabel.stringValue = task.map { "▶ \(displayText($0, limit: 180))" } ?? ""
        taskLabel.isHidden = task == nil
        taskLabel.textColor = .labelColor
        taskLabel.toolTip = taskLabel.stringValue
        let activity = info.lastActivity.flatMap { $0.isEmpty ? nil : $0 } ?? info.lastOutput
        activityLabel.stringValue = displayText(activity, limit: 300)
        activityLabel.isHidden = activity.isEmpty
        activityLabel.toolTip = activity.isEmpty ? nil : displayText(activity, limit: 400)
        let activityTop: CGFloat = task == nil ? 44 : 63
        let measured = (activityLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: max(1, bounds.width - 56), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: activityLabel.font ?? NSFont.systemFont(ofSize: 11)]).height
        let activityHeight: CGFloat = activity.isEmpty ? 0 : min(28, max(14, ceil(measured) + 2))
        activityLabel.frame = NSRect(x: 36, y: activityTop, width: bounds.width - 52, height: activityHeight)
        setFrameSize(NSSize(width: frame.width, height: activityTop + activityHeight + 6))
    }
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
        autoresizingMask = [.width]
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.frame = NSRect(x: 12, y: 10, width: 336, height: 34)
        titleLabel.autoresizingMask = [.width]
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 12, y: 46, width: 336, height: 16)
        subtitleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        if !body.isEmpty {
            scrollView.frame = NSRect(x: 10, y: 66, width: 340, height: bodyHeight)
            scrollView.autoresizingMask = [.width]
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
