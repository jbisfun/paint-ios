import Foundation
import Observation

/// Port of the paint Config (SharedPreferences -> UserDefaults); colors live in FossifyCommons.BaseConfig.
@Observable
final class Config {
    static let shared = Config()

    @ObservationIgnored private let d = UserDefaults.standard

    var showBrushSize: Bool { didSet { d.set(showBrushSize, forKey: "show_brush_size") } }
    var brushColor: UInt32 { didSet { d.set(Int(brushColor), forKey: "brush_color") } }
    var brushSize: Double { didSet { d.set(brushSize, forKey: "brush_size_2") } }
    var canvasBackgroundColor: UInt32 { didSet { d.set(Int(canvasBackgroundColor), forKey: "canvas_background_color") } }
    var lastSaveExtension: String { didSet { d.set(lastSaveExtension, forKey: "last_save_extension") } }
    var allowZoomingCanvas: Bool { didSet { d.set(allowZoomingCanvas, forKey: "allow_zooming_canvas") } }
    var relativeBrushSize: Bool { didSet { d.set(relativeBrushSize, forKey: "relative_brush_size") } }
    var forcePortraitMode: Bool { didSet { d.set(forcePortraitMode, forKey: "force_portrait_mode") } }
    var preventPhoneFromSleeping: Bool { didSet { d.set(preventPhoneFromSleeping, forKey: "prevent_phone_from_sleeping") } }

    private init() {
        showBrushSize = d.object(forKey: "show_brush_size") as? Bool ?? true
        brushColor = (d.object(forKey: "brush_color") as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? 0xFF106D1F
        brushSize = d.object(forKey: "brush_size_2") as? Double ?? 40
        canvasBackgroundColor = (d.object(forKey: "canvas_background_color") as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? 0xFFFFFFFF
        lastSaveExtension = d.string(forKey: "last_save_extension") ?? ""
        allowZoomingCanvas = d.object(forKey: "allow_zooming_canvas") as? Bool ?? true
        relativeBrushSize = d.object(forKey: "relative_brush_size") as? Bool ?? true
        forcePortraitMode = d.object(forKey: "force_portrait_mode") as? Bool ?? false
        preventPhoneFromSleeping = d.object(forKey: "prevent_phone_from_sleeping") as? Bool ?? true
    }
}

/// Constants.kt file extensions.
enum ImageFormat: String, CaseIterable {
    case png, svg, jpg
}
