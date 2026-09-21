import SwiftUI

struct MarkerEditorSheet: View {
    @State var marker: TimelineMarker
    let save: (TimelineMarker) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Marker").font(.headline)
            TextField("Title", text: $marker.title)
            Picker("Type", selection: $marker.type) {
                ForEach(TimelineMarkerType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            LabeledContent("Time", value: ProjectTimecodeFormatter.string(marker.time))
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    marker.title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(marker)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(marker.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
