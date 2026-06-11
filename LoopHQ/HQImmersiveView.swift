//
//  HQImmersiveView.swift
//  LoopHQ
//
//  The fully immersive RealityView that hosts the Salesforce Park world,
//  hand-tracking locomotion, and multiplayer avatars.
//
//  Lifecycle:
//   1. `RealityView { make }` — builds terrain, sky, props; starts
//      hand tracking and multiplayer.
//   2. Per-frame `SceneEvents.Update` subscription — ticks locomotion,
//      broadcasts player state, and pins the camera rig to the terrain.
//   3. On disappear — tears down ARKit session and SharePlay.
//

import SwiftUI
import RealityKit

struct HQImmersiveView: View {

    let worldModel: WorldModel

    @State private var hands = HandTrackingSystem()
    @State private var locomotion: LocomotionController?
    @State private var multiplayer = MultiplayerManager()
    @State private var tickSubscription: EventSubscription?

    /// Broadcast position at a fixed rate rather than every frame.
    @State private var networkAccumulator: Double = 0

    var body: some View {
        RealityView { content in
            // 1. Terrain
            let terrain = WorldRenderer.buildTerrain()
            worldModel.worldRoot.addChild(terrain)
            worldModel.terrainEntity = terrain

            // 2. Sky dome
            let sky = WorldRenderer.buildSkyDome()
            worldModel.worldRoot.addChild(sky)

            // 3. Park props (trees, benches, path)
            WorldRenderer.buildParkProps(parent: worldModel.worldRoot)

            // 4. Camera rig (identity at origin; locomotion moves it)
            worldModel.worldRoot.addChild(worldModel.cameraRig)

            content.add(worldModel.worldRoot)

            // 5. Locomotion controller
            let loco = LocomotionController(hands: hands)
            locomotion = loco
            worldModel.locomotionController = loco

            // 6. Multiplayer
            multiplayer.start(worldRoot: worldModel.worldRoot)
            worldModel.multiplayerManager = multiplayer

            // 7. Per-frame tick
            tickSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                let dt = Float(event.deltaTime)
                loco.update(dt: dt, cameraRig: worldModel.cameraRig)

                // Network broadcast at configured tick rate
                networkAccumulator += event.deltaTime
                let interval = 1.0 / HQConfiguration.networkTickRate
                if networkAccumulator >= interval {
                    networkAccumulator -= interval
                    multiplayer.broadcast(
                        position: loco.position,
                        yaw: loco.yaw,
                        displayName: localPlayerName
                    )
                }
            }
        }
        .task {
            await hands.start()
        }
        .onDisappear {
            hands.stop()
            multiplayer.stop()
            tickSubscription = nil
        }
    }

    /// Best-effort local player name for the avatar label.
    private var localPlayerName: String {
        #if os(visionOS)
        // On device, UIDevice.current.name is "Ash's Apple Vision Pro".
        // Trim the suffix for a cleaner label.
        let raw = UIDevice.current.name
        if let range = raw.range(of: "'s Apple Vision Pro") {
            return String(raw[..<range.lowerBound])
        }
        return raw
        #else
        return "Player"
        #endif
    }
}
