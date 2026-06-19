import SplineRuntime
import SwiftUI

/// Loads the bundled Spline scene off-screen at launch so Metal shaders and
/// scene parsing are warm before `NicknameSetupView` appears.
enum SplineSceneWarmup {
    static let sceneURL = Bundle.main.url(
        forResource: "stickynote",
        withExtension: "splineswift"
    )
}

struct SplineSceneWarmupView: View {
    var body: some View {
        if let sceneURL = SplineSceneWarmup.sceneURL {
            SplineView(sceneFileURL: sceneURL) { phase in
                phase.content
            }
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
