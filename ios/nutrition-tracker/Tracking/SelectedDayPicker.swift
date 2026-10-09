import SwiftUI

/// A compact date control needs its own row when accessibility text grows.
struct SelectedDayPicker: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Binding var selection: Date
    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                Text("Selected day").font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
                DatePicker("Selected day", selection: $selection, displayedComponents: .date)
                    .datePickerStyle(.compact).labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            DatePicker("Selected day", selection: $selection, displayedComponents: .date).datePickerStyle(.compact)
        }
    }
}
