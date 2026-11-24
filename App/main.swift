import FossifyCommons
import PaintKit
import SwiftUI

struct PaintApp: App {
    @UIApplicationDelegateAdaptor(OrientationLockDelegate.self) private var orientation

    var body: some Scene {
        WindowGroup { PaintRoot() }
    }
}

PaintApp.main()
