import Cocoa

/// Build long, read-only trees only when their submenu is opened.
final class ContributionMenus: NSObject, NSMenuDelegate {
    private var builders: [ObjectIdentifier: (NSMenu) -> Void] = [:]

    func reset() { builders.removeAll() }

    func menuNeedsUpdate(_ menu: NSMenu) { menuWillOpen(menu) }

    func menuWillOpen(_ menu: NSMenu) {
        guard let build = builders.removeValue(forKey: ObjectIdentifier(menu)) else { return }
        menu.removeAllItems()
        build(menu)
    }

    private func deferredMenu(_ build: @escaping (NSMenu) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let placeholder = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)
        builders[ObjectIdentifier(menu)] = build
        return menu
    }

    func makeItemsMenu(_ items: [OverviewItem], phase: Int = 0) -> NSMenu {
        deferredMenu { [weak self] menu in
            guard let self = self else { return }
            for item in items { menu.addItem(self.makeItem(item, phase: phase)) }
        }
    }

    private func makeItem(_ value: OverviewItem, phase: Int) -> NSMenuItem {
        let children = value.children ?? []
        let title = displayText(value.title, limit: 80) + (value.kind == "group" ? " (\(children.count))" : "")
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let symbol: String
        switch value.kind {
        case "note": symbol = value.state == "cancelled" ? "note.text.badge.minus" : "note.text"
        case "group": symbol = value.title == "Notes" ? "text.bubble" : "list.bullet.indent"
        case "job" where value.state == nil || value.state == "unknown": symbol = "terminal"
        default: symbol = statusSymbolName(value.state)
        }
        row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: value.kind ?? value.state)
        if row.image == nil { row.title = "\(itemSymbol(value.state, phase: phase)) \(title)" }
        row.image?.size = NSSize(width: 14, height: 14)
        row.attributedTitle = NSAttributedString(string: row.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: value.kind == "group" ? .semibold : .regular)])
        let detail = value.detail ?? ""
        row.isEnabled = !detail.isEmpty || !(value.body ?? "").isEmpty || !children.isEmpty
        row.toolTip = detail.isEmpty ? nil : detail
        if row.isEnabled {
            row.submenu = deferredMenu { [weak self] menu in
                guard let self = self else { return }
                if !detail.isEmpty || !(value.body ?? "").isEmpty {
                    let card = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
                    card.view = ContributionCard(value)
                    menu.addItem(card)
                }
                if !children.isEmpty && (!detail.isEmpty || !(value.body ?? "").isEmpty) { menu.addItem(.separator()) }
                for child in children { menu.addItem(self.makeItem(child, phase: phase)) }
                if !detail.isEmpty {
                    menu.addItem(.separator())
                    let copy = NSMenuItem(title: "Copy details", action: #selector(self.copyDetails(_:)), keyEquivalent: "")
                    copy.target = self
                    copy.representedObject = detail
                    menu.addItem(copy)
                }
            }
        }
        return row
    }

    @objc private func copyDetails(_ sender: NSMenuItem) {
        guard let detail = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail, forType: .string)
    }
}
