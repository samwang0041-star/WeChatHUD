import AppKit

/// Status-item menu: open the companion, check messages, then quieter
/// destinations. Titles stay in customer language.
enum StatusBarMenuSpec {
    struct Row: Equatable {
        enum Kind: Equatable {
            case command(title: String, key: String)
            case separator
        }
        var kind: Kind
        var isSeparator: Bool {
            if case .separator = kind { return true }
            return false
        }
    }

    enum Action: Equatable {
        case toggleCompanion
        case refresh
        case timeReview
        case guide
        case updates
        case quit
    }

    static func rows(companionOpen: Bool, updateVersion: String?) -> [Row] {
        [
            Row(kind: .command(title: CompanionProductCopy.companionToggleTitle(isOpen: companionOpen), key: "1")),
            Row(kind: .command(title: CompanionProductCopy.checkNewMessages, key: "r")),
            Row(kind: .separator),
            Row(kind: .command(title: CompanionProductCopy.timeReview, key: "R")),
            Row(kind: .command(title: CompanionProductCopy.howToUse, key: "?")),
            Row(kind: .command(title: updateTitle(updateVersion), key: "")),
            Row(kind: .separator),
            Row(kind: .command(title: CompanionProductCopy.quitCompanion, key: "q"))
        ]
    }

    static func actions() -> [Action?] {
        [.toggleCompanion, .refresh, nil, .timeReview, .guide, .updates, nil, .quit]
    }

    static func updateTitle(_ version: String?) -> String {
        if let version, !version.isEmpty {
            return CompanionProductCopy.viewUpdate(version)
        }
        return CompanionProductCopy.checkUpdates
    }
}

enum StatusBarMenuBuilder {
    static func makeMenu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        let actions = StatusBarMenuSpec.actions()
        for (index, row) in StatusBarMenuSpec.rows(companionOpen: false, updateVersion: nil).enumerated() {
            switch row.kind {
            case .separator:
                menu.addItem(.separator())
            case .command(let title, let key):
                let item = NSMenuItem(title: title, action: selector(for: actions[index]), keyEquivalent: key)
                item.target = target
                menu.addItem(item)
            }
        }
        return menu
    }

    private static func selector(for action: StatusBarMenuSpec.Action?) -> Selector? {
        switch action {
        case .toggleCompanion: return #selector(AppDelegate.toggleCompanionFromMenu)
        case .refresh: return #selector(AppDelegate.refreshNow)
        case .timeReview: return #selector(AppDelegate.openRetrospective)
        case .guide: return #selector(AppDelegate.openGuide)
        case .updates: return #selector(AppDelegate.checkForUpdates)
        case .quit: return #selector(AppDelegate.quitApp)
        case nil: return nil
        }
    }
}
