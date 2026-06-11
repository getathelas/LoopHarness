import SwiftUI

/// Entry point for **Loop HQ** — Loop's multiplayer spatial hangout.
///
/// A small lobby window launches a fully immersive, photorealistic
/// reconstruction of Salesforce Park (San Francisco) rendered from Google's
/// photogrammetry tiles (satellite imagery fallback). The wearer walks the
/// park at human scale with pinch-drag hand controls, pinned to the ground
/// by gravity, and SharePlay participants appear as avatars in the same
/// park-local coordinate frame.
@main
struct LoopHQApp: App {
    @State private var model = HQAppModel()

    var body: some Scene {
        WindowGroup {
            HQLobbyView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 640)

        ImmersiveSpace(id: HQAppModel.immersiveSpaceID) {
            ParkImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
