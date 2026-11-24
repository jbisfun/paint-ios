import FossifyCommons
import SwiftUI
import UniformTypeIdentifiers

/// dialogs/SaveImageDialog.kt (the scoped-storage variant: no folder, the system picks it).
struct SaveImageDialog: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let defaultFilename: String
    let defaultExtension: String
    let onToast: (String) -> Void
    let onSave: (_ filename: String, _ format: ImageFormat) -> Void

    @State private var filename = ""
    @State private var format = ImageFormat.png
    @FocusState private var focused: Bool

    var body: some View {
        DialogFrame(title: "Save as") {
            TextField("Filename", text: $filename)
                .font(.system(size: 18))
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.primaryColor).frame(height: 1) }
                .padding(.bottom, 8)
            ForEach([ImageFormat.png, .svg, .jpg], id: \.self) { f in
                Button { format = f } label: { RadioRow(title: ".\(f.rawValue)", on: format == f) }
                    .buttonStyle(.plain)
            }
            DialogButtons {
                let name = filename.trimmingCharacters(in: .whitespaces)
                if name.isEmpty {
                    onToast("Filename cannot be empty")
                } else if !"\(name).\(format.rawValue)".isAValidFilename {
                    onToast("Filename contains invalid characters")
                } else {
                    dismiss()
                    onSave(name, format)
                }
            }
        }
        .onAppear {
            filename = defaultFilename.isEmpty ? "image_\(DateTimeFormat.format(Date(), "yyyyMMdd_HHmmss"))" : defaultFilename
            format = ImageFormat(rawValue: defaultExtension) ?? .png
            focused = true
        }
    }
}

extension String {
    /// isAValidFilename().
    var isAValidFilename: Bool {
        !contains { "/\n\r\t\u{0}`?*\\<>|\":".contains($0) }
    }
}

/// The bytes handed to the system save panel (Intent.ACTION_CREATE_DOCUMENT).
struct ImageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .jpeg, .svg] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
