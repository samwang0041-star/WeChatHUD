import SwiftUI

/// One page frame for the whole workspace.
///
/// Why this exists: every page used to spell its own geometry — 1180 here,
/// 960 there, 920 in the guide, a 20pt side padding in the report and the
/// radar — and the sidebar's page header was sized from a *different* list of
/// literals than the bodies underneath it. The result was visible the moment
/// you switched entries: on some pages the filters lined up with the title
/// block and on others they started a hundred points to the left, and two
/// pages that both claimed a max width did not line up with each other.
///
/// So the numbers live here, once, and both the header and the body read them.
/// A page now only chooses a *family*:
///
///   - wideWidth for pages that are a list plus a detail pane (待办, 草稿,
///     关注谁, 聊天回顾, 关系雷达, 待确认回复) — they need the room.
///   - narrowWidth for single-column pages: settings forms and reading
///     pages (AI 服务, 提醒方式, 今日小结, 怎么用 …). A form stretched to
///     1180pt puts its controls a screen away from their labels.
///
/// The two families are a deliberate difference in *width*; everything else —
/// the side inset, the gap under the header, the gap above the status bar —
/// is shared, which is what makes the pages read as one product.
enum WorkspacePage {
    /// Pages built as a list plus a detail pane.
    static let wideWidth: CGFloat = 1180
    /// Single-column pages: settings forms and reading pages.
    static let narrowWidth: CGFloat = 960
    /// Leading/trailing inset. Shared with the page header, so the two can
    /// never disagree about where the page starts.
    static let inset: CGFloat = 28
    /// Air between the page header and the page body.
    static let headerGap: CGFloat = 12
    /// Top inset for a page that draws its own header instead of using the
    /// shared one (怎么用). Equal to the shared header's own top padding, so
    /// its first line still lands on the same baseline as every other page's
    /// title block.
    static let selfHeadedTopGap: CGFloat = 20
    /// Air under a page body, above the status bar.
    static let bottomGap: CGFloat = 20

    /// The ground a page paints under its own content.
    ///
    /// One value, because three were in use. 待办 / 我答应的事 / 关注谁 painted
    /// the warm off-white (`CompanionPalette.canvas`); 今日小结 / 关系雷达 /
    /// 聊天回顾's detail column painted the cooler system
    /// `windowBackgroundColor`; 草稿 painted nothing and let the window's own
    /// tinted backdrop through. Switching sections therefore flipped the room
    /// from warm to cold to transparent with no rule behind it, which is part
    /// of why the pages did not read as one product. The warm canvas wins
    /// because it is the one the material system was measured against.
    static var ground: Color { CompanionPalette.canvas }
}

extension View {
    /// The standard workspace page body.
    ///
    /// Inset, capped at the family width and pinned to the top of whatever
    /// height is left after the header — so the status bar stays at the
    /// bottom of the window instead of floating under a short page.
    func workspacePage(_ width: CGFloat) -> some View {
        self
            .frame(maxWidth: width, alignment: .leading)
            .padding(.horizontal, WorkspacePage.inset)
            .padding(.bottom, WorkspacePage.bottomGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Opaque page ground in the shared colour. For pages whose content is not
    /// already a filled surface of its own (a split view, a card list, a
    /// report). Pages that paint their own cards directly on the window
    /// backdrop leave this off deliberately.
    func workspaceGround() -> some View {
        background(WorkspacePage.ground)
    }
}
