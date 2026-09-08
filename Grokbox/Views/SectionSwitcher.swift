import SwiftUI

/// The five-way section switcher that lives in the toolbar's glass capsule.
///
/// Labelled rather than icon-only: five glyphs is more than anyone should have
/// to learn, and the words remove the guesswork the hover highlight used to
/// paper over. Each item is a plain button, so the only thing that changes
/// under the pointer is the pointer.
struct SectionSwitcher: View {
    @Binding var section: AppSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 12, weight: section == item ? .semibold : .regular))
                            .fixedSize()
                    }
                    .foregroundStyle(section == item ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }
        }
        .fixedSize()
        .accessibilityIdentifier("sectionPicker")
    }
}
