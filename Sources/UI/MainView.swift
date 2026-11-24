import FossifyCommons
import PhotosUI
import _PhotosUI_SwiftUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// MainActivity.
struct MainView: View {
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette
    @Environment(\.finishApp) private var finishApp

    @State private var canvas = PaintCanvas()
    @State private var isEyeDropperOn = false
    @State private var brushSize: Double = 40
    @State private var started = false

    @State private var defaultFilename = ""
    @State private var defaultExtension = ImageFormat.png.rawValue
    /// uriToLoad: the opened file, reloaded after a background color change.
    @State private var source: (data: Data, name: String)?
    @State private var savedPathsHash = 0
    @State private var lastSavePromptTS = Date.distantPast
    @State private var closeAfterSaving = false

    @State private var pickBrushColor = false
    @State private var pickBackgroundColor = false
    @State private var confirmClear = false
    @State private var showSaveDialog = false
    @State private var pendingExport: (doc: ImageDocument, type: UTType, name: String)?
    @State private var exporting = false
    @State private var shareItem: ShareItems?
    @State private var chooseOpenSource = false
    @State private var importing = false
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var savePrompt = false

    private var contrast: Color { canvas.backgroundColor.contrastColor }

    var body: some View {
        mainContent
            // The launcher's navigation bar Back on the main screen (onBackPressedCompat).
            .onBackPressed { close() }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                CanvasRepresentable(canvas: canvas, eyeDropper: isEyeDropperOn ? { setColor($0) } : nil)
                tools
                if config.showBrushSize && !isEyeDropperOn && !canvas.isBucketFillOn { brushSizeTool }
            }
            .clipped()
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .onAppear(perform: start)
        .onChange(of: config.allowZoomingCanvas) { canvas.allowMovingZooming = config.allowZoomingCanvas }
        .onChange(of: config.relativeBrushSize) { canvas.relativeBrushSize = config.relativeBrushSize }
        .onChange(of: router.openURL) { if let url = router.openURL { router.openURL = nil; open(url) } }
        .sheet(isPresented: $pickBrushColor) {
            ColorPickerDialog(title: "Change color", color: canvas.color) { c in
                if isEyeDropperOn { eyeDropperClicked() }
                setColor(c)
            }
        }
        .sheet(isPresented: $pickBackgroundColor) {
            ColorPickerDialog(title: "Change background color", color: canvas.backgroundColor) { c in
                config.canvasBackgroundColor = c
                setBackgroundColor(c)
                if let source { load(source.data, name: source.name) }
            }
        }
        .sheet(isPresented: $showSaveDialog, onDismiss: {
            if pendingExport != nil { exporting = true }
        }) {
            SaveImageDialog(defaultFilename: defaultFilename, defaultExtension: defaultExtension,
                            onToast: { router.toast = $0 }) { filename, format in
                defaultFilename = filename
                defaultExtension = format.rawValue
                config.lastSaveExtension = format.rawValue
                prepareExport(filename, format)
            }
        }
        .onChange(of: pendingExport != nil) { if pendingExport != nil && !showSaveDialog { exporting = true } }
        .fileExporter(isPresented: $exporting, document: pendingExport?.doc, contentType: pendingExport?.type ?? .png,
                      defaultFilename: pendingExport?.name) { result in
            switch result {
            case .success:
                savedPathsHash = canvas.getDrawingHashCode()
                router.toast = "File saved successfully"
                if closeAfterSaving { finishApp?() }
            case .failure(let error):
                router.toast = error.localizedDescription
            }
            closeAfterSaving = false
            pendingExport = nil
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: item.urls).ignoresSafeArea() }
        .alert("Are you sure you want to clear the canvas?", isPresented: $confirmClear) {
            Button("Yes") { clearCanvas() }
            Button("No", role: .cancel) {}
        }
        .alert("You have unsaved changes. Save before exit?", isPresented: $savePrompt) {
            Button("Save") {
                closeAfterSaving = true
                trySaveImage()
            }
            Button("Discard", role: .destructive) { finishApp?() }
        }
        .confirmationDialog("Open file", isPresented: $chooseOpenSource) {
            Button("Photos") { pickingPhoto = true }
            Button("Files") { importing = true }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    load(data, name: "image")
                } else {
                    router.toast = "Invalid file format"
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .svg]) { result in
            if case .success(let url) = result { open(url) }
        }
    }

    // MARK: top app bar + menu

    private var topBar: some View {
        HStack(spacing: 0) {
            Spacer()
            IconButton(icon: "square.and.arrow.down") { trySaveImage() }
            IconButton(icon: "trash") { displayClearCanvasPrompt() }
            IconButton(icon: "square.and.arrow.up") { shareImage() }
            Menu {
                Button("Open file") { chooseOpenSource = true }
                Button("Change background color") { pickBackgroundColor = true }
                Button("Print") { printImage() }
                Button("Settings") { router.push(.settings) }
                Button("About") { router.push(.about) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 19)).frame(width: 44, height: 48)
            }
        }
        .foregroundStyle(palette.textColor)
        .padding(.horizontal, 4)
        .frame(height: 56)
    }

    // MARK: canvas tools

    private var tools: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 0) {
                if canvas.canRedo {
                    tool("arrow.uturn.forward", "Redo", tint: contrast) { canvas.redo() }
                }
                tool("drop.fill", "Bucket fill", tint: canvas.isBucketFillOn ? palette.primaryColor : contrast) { bucketFillClicked() }
                tool("eraser", "Eraser", tint: canvas.isEraserOn ? palette.primaryColor : contrast) { eraserClicked() }
                tool("eyedropper", "Eyedropper", tint: isEyeDropperOn ? palette.primaryColor : contrast) { eyeDropperClicked() }
                Button { pickBrushColor = true } label: {
                    Circle()
                        .fill(Color(argb: canvas.color))
                        .overlay(Circle().stroke(contrast.opacity(0.5), lineWidth: 1))
                        .frame(width: 32, height: 32)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Change color")
            }
            if canvas.canUndo {
                tool("arrow.uturn.backward", "Undo", tint: contrast) { canvas.undo() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func tool(_ icon: String, _ name: String, tint: Color, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 20))
            .foregroundStyle(tint)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onLongPressGesture { router.toast = name }
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isButton)
    }

    private var brushSizeTool: some View {
        VStack(spacing: 8) {
            Spacer()
            Circle()
                .fill(Color(argb: canvas.color))
                .overlay(Circle().stroke(contrast, lineWidth: 1 / max(0.03, brushSize / 100)))
                .frame(width: PaintCanvas.fullBrushSize, height: PaintCanvas.fullBrushSize)
                .scaleEffect(max(0.03, brushSize / 100))
                .allowsHitTesting(false)
            Slider(value: $brushSize, in: 5...100)
                .tint(palette.primaryColor)
                .frame(width: 150)
                .padding(8)
                .onChange(of: brushSize) {
                    canvas.setBrushSize(brushSize)
                    config.brushSize = brushSize
                }
        }
        .padding(.bottom, 12)
    }

    // MARK: actions

    private func start() {
        guard !started else { return }
        started = true
        canvas.onError = { router.toast = $0 }
        canvas.allowMovingZooming = config.allowZoomingCanvas
        canvas.relativeBrushSize = config.relativeBrushSize
        setBackgroundColor(config.canvasBackgroundColor)
        setColor(config.brushColor)
        defaultExtension = config.lastSaveExtension.isEmpty ? ImageFormat.png.rawValue : config.lastSaveExtension
        brushSize = max(5, config.brushSize)
        canvas.setBrushSize(brushSize)
        if let url = router.openURL {
            router.openURL = nil
            DispatchQueue.main.async { open(url) }
        }
    }

    private func setColor(_ c: UInt32) {
        canvas.color = c
        config.brushColor = c
        canvas.isEraserOn = false
    }

    private func setBackgroundColor(_ c: UInt32) {
        if isEyeDropperOn { eyeDropperClicked() }
        canvas.updateBackgroundColor(c)
        defaultExtension = ImageFormat.png.rawValue
    }

    private func eraserClicked() {
        if isEyeDropperOn { eyeDropperClicked() } else if canvas.isBucketFillOn { bucketFillClicked() }
        canvas.isEraserOn.toggle()
    }

    private func eyeDropperClicked() {
        if canvas.isEraserOn { eraserClicked() } else if canvas.isBucketFillOn { bucketFillClicked() }
        isEyeDropperOn.toggle()
    }

    private func bucketFillClicked() {
        if canvas.isEraserOn { eraserClicked() } else if isEyeDropperOn { eyeDropperClicked() }
        canvas.isBucketFillOn.toggle()
    }

    private func displayClearCanvasPrompt() {
        if canvas.hasContent { confirmClear = true } else { clearCanvas() }
    }

    private func clearCanvas() {
        source = nil
        canvas.clearCanvas()
        defaultExtension = ImageFormat.png.rawValue
    }

    /// onBackPressedCompat(): offer to save unsaved changes before leaving.
    private func close() {
        let unsaved = canvas.hasPendingEdits || savedPathsHash != canvas.getDrawingHashCode()
        if unsaved && Date().timeIntervalSince(lastSavePromptTS) > 1 {
            lastSavePromptTS = Date()
            savePrompt = true
        } else {
            finishApp?()
        }
    }

    // MARK: open

    private func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            router.toast = "Failed to load image \(url.lastPathComponent)"
            return
        }
        load(data, name: url.lastPathComponent)
    }

    /// tryOpenUri() / openUri(): SVGs replace the drawing, images become its background.
    private func load(_ data: Data, name: String) {
        let isSvg = name.lowercased().hasSuffix(".svg") || data.prefix(512).range(of: Data("<svg".utf8)) != nil
        if isSvg {
            do {
                let svg = try Svg.parse(data)
                canvas.replaceDrawing(svg)
                source = (data, name)
                defaultExtension = ImageFormat.svg.rawValue
            } catch {
                router.toast = "An unknown error occurred"
            }
        } else if let image = UIImage(data: data) {
            drawBitmap(image)
            source = (data, name)
            defaultExtension = ImageFormat.jpg.rawValue
        } else {
            router.toast = "Invalid file format"
        }
    }

    /// drawBitmap(): fit-center into the canvas.
    private func drawBitmap(_ image: UIImage) {
        let bounds = canvas.viewSize.width > 0 ? canvas.viewSize : UIScreen.main.bounds.size
        let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: (image.size.width * ratio).rounded(), height: (image.size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = scaled.cgImage else {
            router.toast = "Failed to load image"
            return
        }
        canvas.setBackgroundImage(.init(image: cg, size: size))
    }

    // MARK: save / share / print

    private func trySaveImage() {
        showSaveDialog = true
    }

    private func prepareExport(_ filename: String, _ format: ImageFormat) {
        canvas.whenDrawingReady {
            let data: Data?
            let type: UTType
            switch format {
            case .svg:
                let size = canvas.viewSize
                data = Data(Svg.write(operations: canvas.operations, backgroundColor: canvas.backgroundColor,
                                      width: Int(size.width), height: Int(size.height), viewport: canvas.viewportBounds()).utf8)
                type = .svg
            case .png:
                data = canvas.image().pngData()
                type = .png
            case .jpg:
                data = canvas.image().jpegData(compressionQuality: 0.7)
                type = .jpeg
            }
            guard let data else {
                router.toast = "An unknown error occurred"
                return
            }
            pendingExport = (ImageDocument(data: data), type, filename)
        }
    }

    private func shareImage() {
        canvas.whenDrawingReady {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("images", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("simple-paint.png")
            guard let data = canvas.image().pngData(), (try? data.write(to: url)) != nil else {
                router.toast = "An unknown error occurred"
                return
            }
            shareItem = ShareItems([url])
        }
    }

    private func printImage() {
        canvas.whenDrawingReady {
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.jobName = "Paint"
            info.outputType = .photo
            controller.printInfo = info
            controller.printingItem = canvas.image()
            controller.present(animated: true)
        }
    }
}
