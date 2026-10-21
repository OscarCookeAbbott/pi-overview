import Cocoa

final class AgentPromptEditor: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { onSubmit?(); return }
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let origin = textContainerOrigin
            let placeholderX = origin.x + (textContainer?.lineFragmentPadding ?? 0)
            ("What should the agent do?" as NSString).draw(at: NSPoint(x: placeholderX, y: origin.y), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
}

/// A persistent draft embedded directly in the status menu, not a modal prompt.
final class AgentComposer: NSView, NSTextViewDelegate {
    let editor = AgentPromptEditor()
    let directoryLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let startButton = NSButton(title: "⌘↩", target: nil, action: nil)
    let directoryButton = NSButton(title: "", target: nil, action: nil)
    var directoryPicker: (String?) -> String? = { current in
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Agent directory"
        panel.prompt = "Use directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let current = current { panel.directoryURL = URL(fileURLWithPath: current) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    private let onSubmit: (String, String) throws -> Void
    private let scroll = NSScrollView()
    private var defaultDirectory: String?
    private var selectedDirectory: String?
    var directory: String? { selectedDirectory ?? defaultDirectory }
    private var configurationError: String?
    private var submissionError: String?
    private var submitting = false
    override var isFlipped: Bool { true }

    var prompt: String {
        get { editor.string }
        set { editor.string = newValue; submissionError = nil; updateState() }
    }

    init(onSubmit: @escaping (String, String) throws -> Void) {
        self.onSubmit = onSubmit
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 104))
        identifier = NSUserInterfaceItemIdentifier("overview.agent-composer")
        autoresizingMask = [.width]
        scroll.frame = NSRect(x: 12, y: 10, width: 336, height: 54)
        scroll.autoresizingMask = [.width]
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.masksToBounds = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        editor.frame = NSRect(origin: .zero, size: scroll.contentSize)
        editor.font = .systemFont(ofSize: 12)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 54)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.delegate = self
        editor.setAccessibilityLabel("New agent prompt")
        editor.toolTip = "⌘Return starts the agent. Escape closes the menu and keeps the draft."
        editor.onSubmit = { [weak self] in self?.submit(nil) }
        editor.onCancel = { [weak self] in self?.enclosingMenuItem?.menu?.cancelTracking() }
        scroll.documentView = editor
        addSubview(scroll)
        directoryButton.frame = NSRect(x: 12, y: 70, width: 24, height: 24)
        directoryButton.isBordered = false
        directoryButton.controlSize = .small
        directoryButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose agent directory")
        directoryButton.imagePosition = .imageOnly
        directoryButton.setAccessibilityLabel("Choose directory for this agent")
        directoryButton.target = self
        directoryButton.action = #selector(chooseDirectory(_:))
        addSubview(directoryButton)
        directoryLabel.font = .systemFont(ofSize: 11)
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.frame = NSRect(x: 42, y: 74, width: 238, height: 16)
        directoryLabel.autoresizingMask = [.width]
        addSubview(directoryLabel)
        startButton.frame = NSRect(x: 288, y: 70, width: 60, height: 24)
        startButton.autoresizingMask = [.minXMargin]
        startButton.bezelStyle = .rounded
        startButton.controlSize = .small
        startButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        startButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Start agent")
        startButton.image?.size = NSSize(width: 12, height: 12)
        startButton.imagePosition = .imageLeft
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = [.command]
        startButton.toolTip = "Start agent (⌘Return). Escape keeps the draft."
        startButton.setAccessibilityLabel("Start agent")
        startButton.target = self
        startButton.action = #selector(submit(_:))
        addSubview(startButton)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.frame = NSRect(x: 42, y: 70, width: 238, height: 28)
        errorLabel.autoresizingMask = [.width]
        addSubview(errorLabel)
        updateBorder()
        updateState()
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func configure(directory: String?, error: String? = nil) {
        defaultDirectory = directory
        configurationError = error
        updateState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self = self, let window = window, self.window === window, window.isVisible else { return }
            window.makeFirstResponder(self.editor)
        }
    }

    func textDidChange(_ notification: Notification) {
        submissionError = nil
        updateState()
    }

    @objc func chooseDirectory(_ sender: Any?) {
        guard let chosen = directoryPicker(directory) else { return }
        selectedDirectory = chosen
        submissionError = nil
        updateState()
    }

    private func updateState() {
        directoryLabel.stringValue = directory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Choose a directory"
        directoryLabel.toolTip = directory
        directoryButton.toolTip = directory.map { "Choose agent directory\n\($0)" } ?? "Choose agent directory"
        var isDirectory: ObjCBool = false
        let validDirectory = directory.map { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue } ?? false
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let tooLong = value.utf8.count > 65536
        var error = configurationError ?? submissionError
        if configurationError == nil {
            if !validDirectory { error = "Choose an existing agent directory." }
            else if tooLong { error = "Please keep prompts under 64 KiB." }
        }
        errorLabel.stringValue = error ?? ""
        errorLabel.toolTip = error
        errorLabel.isHidden = error == nil
        directoryLabel.isHidden = error != nil
        startButton.isEnabled = !submitting && configurationError == nil && validDirectory && !value.isEmpty && !tooLong
        directoryButton.isEnabled = !submitting
        editor.needsDisplay = true
    }

    @objc func submit(_ sender: Any?) {
        updateState()
        guard startButton.isEnabled, let directory = directory else { return }
        submitting = true
        updateState()
        do {
            try onSubmit(prompt.trimmingCharacters(in: .whitespacesAndNewlines), directory)
            editor.string = ""
            selectedDirectory = nil
            submissionError = nil
        } catch { submissionError = error.localizedDescription }
        submitting = false
        updateState()
    }
}
