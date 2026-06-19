import SwiftUI
import Combine
import UIKit

struct ContentView: View {
    @State private var model = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            RoomView(model: model)
            SplineSceneWarmupView()
        }
        .onChange(of: scenePhase) { _, phase in
            model.isAppActive = (phase == .active)
            if phase == .active {
                model.refreshBluetoothState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            model.mesh.sendLeave()
        }
    }
}

#Preview {
    ContentView()
}
