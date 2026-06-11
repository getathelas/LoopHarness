import SwiftUI

/// Entry point for **Loop HQ** — Loop's multiplayer spatial hangout.
///
/// A small lobby window launches a fully immersive, stylised voxel world:
/// UC Berkeley's Campanile on a floating plaza platform, rendered as chunky
/// unlit blocks (the Minecraft look hides every fidelity gap photoreal
/// tiles exposed). The wearer walks at human scale with a left-hand
/// pinch-stick, looks with their head, and tilts the view with a 1:1
/// right-hand pinch-and-drag; SharePlay participants appear as avatars in
/// the same world frame.
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
            HQImmersiveView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
