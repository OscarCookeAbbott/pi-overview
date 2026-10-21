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
        fitMenuViews(menu)
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

    func makeAgentItems(_ info: InstanceInfo, actions: NSMenu, phase: Int = 0, refresh: (() -> InstanceInfo?)? = nil) -> [NSMenuItem] {
        let summary = NSMenuItem(title: displayText(info.sessionName ?? info.projectName), action: nil, keyEquivalent: "")
        summary.view = AgentCard(info)
        var rows = [summary]
        for contribution in menuContributions(info) {
            for (sectionIndex, section) in contribution.sections.enumerated() where !section.items.isEmpty {
                let badge = contribution.id == "tasks" && contribution.badge.hasSuffix(" tasks") ? String(contribution.badge.dropLast(6)) : contribution.badge
                let title = displayText(section.title, limit: 40) + (badge.isEmpty ? "" : " · \(displayText(badge, limit: 30))")
                let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                row.identifier = NSUserInterfaceItemIdentifier("overview.contribution.\(info.id).\(contribution.id).\(sectionIndex)")
                row.indentationLevel = 1
                let currentItems: () -> [OverviewItem] = {
                    let current: InstanceInfo
                    if let refresh = refresh {
                        guard let latest = refresh() else { return [] }
                        current = latest
                    } else { current = info }
                    guard let latest = menuContributions(current).first(where: { $0.id == contribution.id }),
                          latest.sections.indices.contains(sectionIndex), latest.sections[sectionIndex].title == section.title else { return [] }
                    return latest.sections[sectionIndex].items
                }
                row.submenu = contribution.id == "tasks" ? makeTasksMenu(currentItems, phase: phase) : makeItemsMenu(currentItems, phase: phase)
                row.image = NSImage(systemSymbolName: contribution.id == "jobs" ? "terminal" : "list.bullet", accessibilityDescription: section.title)
                row.image?.size = NSSize(width: 14, height: 14)
                rows.append(row)
            }
        }
        let controls = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        controls.indentationLevel = 1
        controls.submenu = actions
        rows.append(controls)
        return rows
    }

    private func makeTasksMenu(_ items: @escaping () -> [OverviewItem], phase: Int) -> NSMenu {
        deferredMenu { [weak self] menu in
            guard let self = self else { return }
            func append(_ value: OverviewItem, depth: Int) {
                let children = value.children ?? []
                let subtasks = children.filter { $0.kind == "task" || $0.kind == nil || ($0.kind == "group" && $0.title == "Subtasks") }
                var detail = value
                detail.children = children.filter { $0.kind != "task" && $0.kind != nil && !($0.kind == "group" && $0.title == "Subtasks") }
                let row = self.makeItem(detail, phase: phase)
                row.indentationLevel = depth
                menu.addItem(row)
                for child in subtasks {
                    if child.kind == "group" {
                        for task in child.children ?? [] { append(task, depth: depth + 1) }
                    } else { append(child, depth: depth + 1) }
                }
            }
            for item in items() { append(item, depth: 0) }
            if menu.items.isEmpty { menu.addItem(self.emptyItem()) }
        }
    }

    func makeItemsMenu(_ items: [OverviewItem], phase: Int = 0) -> NSMenu {
        makeItemsMenu({ items }, phase: phase)
    }

    private func makeItemsMenu(_ items: @escaping () -> [OverviewItem], phase: Int) -> NSMenu {
        deferredMenu { [weak self] menu in
            guard let self = self else { return }
            for item in items() { menu.addItem(self.makeItem(item, phase: phase)) }
            if menu.items.isEmpty { menu.addItem(self.emptyItem()) }
        }
    }

    private func emptyItem() -> NSMenuItem {
        let item = NSMenuItem(title: "No items", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
