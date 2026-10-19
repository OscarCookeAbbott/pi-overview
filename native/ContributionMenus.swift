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
        let row = NSMenuItem(title: "\(itemSymbol(value.state, phase: phase)) \(displayText(value.title, limit: 80))", action: nil, keyEquivalent: "")
        let detail = value.detail ?? ""
        let children = value.children ?? []
        row.isEnabled = !detail.isEmpty || !children.isEmpty
        row.toolTip = detail.isEmpty ? nil : detail
        if row.isEnabled {
            row.submenu = deferredMenu { [weak self] menu in
                guard let self = self else { return }
                for child in children { menu.addItem(self.makeItem(child, phase: phase)) }
                if !children.isEmpty && !detail.isEmpty { menu.addItem(.separator()) }
                if !detail.isEmpty {
                    for line in self.detailLines(detail) {
                        let text = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                        text.isEnabled = false
                        menu.addItem(text)
                    }
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

    private func detailLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { part -> [String] in
            var remaining = displayText(part, limit: part.count)[...]
            if remaining.isEmpty { return [" "] }
            var lines: [String] = []
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: 88, limitedBy: remaining.endIndex) ?? remaining.endIndex
                lines.append(String(remaining[..<end]))
                remaining = remaining[end...]
            }
            return lines
        }
    }

    @objc private func copyDetails(_ sender: NSMenuItem) {
        guard let detail = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail, forType: .string)
    }
}
