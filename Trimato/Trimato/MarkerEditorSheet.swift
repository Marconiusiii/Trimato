import SwiftUI

struct MarkerEditorSheet: View {
    @AppStorage(AppPreferenceKey.precisionTimecode) private var precisionTimecode = true
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
            Text("Marker position: \(AppPreferences.passiveTimecode(seconds: marker.time.seconds, precision: precisionTimecode))")
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
