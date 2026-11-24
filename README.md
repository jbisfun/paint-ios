# paint-ios

[Fossify Paint](https://github.com/FossifyOrg/Paint) re-created for iOS in SwiftUI, drawing with Core Graphics.

    idl build -c release     # -> build/release/FossifyPaint.ipa (ad-hoc signed; re-sign to install)
    idl install "<device>" FossifyPaint

Ported: the canvas with smoothed strokes, dots, eraser, eyedropper and vector bucket fill (connected same-color region, also over opened images), undo/redo of up to 1000 steps (including undoing a clear), two-finger zooming and moving, brush color picker and brush size tool; save as PNG, SVG or JPG with the last format remembered, share, print, open images and SVGs (also Fossify Paint's own SVGs) from Photos or Files and via "Open in", change background color, unsaved-changes prompt; colors and every setting (keep screen on, brush size tool, zooming, zoom-relative brush size, force portrait).

Differences forced by iOS: the system save panel picks the folder, there is no "take a picture"/"edit" mode for other apps (no IMAGE_CAPTURE/EDIT intents), the color picker is the system one, no in-app language switch, and tool icons are SF Symbols.

GPL-3.0, like the original.
