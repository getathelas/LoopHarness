import RealityKit
import SwiftUI

/// The immersive scene: hosts the world root and drives the per-frame loop.
struct ParkImmersiveView: View {
    @Environment(HQAppModel.self) private var model
    @State private var updateSubscription: EventSubscription?

    var body: some View {
        RealityView { content in
            content.add(model.world.root)
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                model.tick(dt: Float(event.deltaTime))
            }
        }
        .task {
            await model.enteredPark()
        }
        .onDisappear {
            updateSubscription?.cancel()
            updateSubscription = nil
            model.leftPark()
        }
    }
}
