import MarkTextKit
import SwiftUI

struct OutlineSidebar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        let headings = model.headings
        let base = headings.map(\.level).min() ?? 1
        List(selection: Binding(get: { model.activeHeading ?? headings.first?.id }, set: { id in
            guard let id else { return }
            model.activeHeading = id
            model.preview.scrollToHeading(id)
        })) {
            ForEach(headings) { h in
                Text(h.title)
                    .font(.system(size: 13, weight: h.level == base ? .medium : .regular))
                    .foregroundStyle(h.level == base ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, CGFloat(h.level - base) * 14)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .tag(h.id)
            }
        }
        .environment(\.defaultMinListRowHeight, 22)
        .environment(\.sidebarRowSize, .small)
        .overlay {
            if headings.isEmpty { ContentUnavailableView("No Headings", systemImage: "list.bullet.indent") }
        }
    }
}
