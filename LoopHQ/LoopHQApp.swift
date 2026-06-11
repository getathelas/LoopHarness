//
//  LoopHQApp.swift
//  LoopHQ
//
//  Entry point for the Loop HQ visionOS target — a multiplayer, photoreal
//  walkable world rendered from satellite/photogrammetry imagery of
//  Salesforce Park, San Francisco.
//
//  Two scenes:
//   1. A small 2D lobby window with a "Enter HQ" button.
//   2. A fully immersive space (`.mixed` passthrough + RealityKit) that opens
//      the world, pins the user to the terrain, and starts multiplayer.
//
//  The lobby window dismisses itself once the immersive space opens.
//

import SwiftUI

@main
struct LoopHQApp: App {

    @State private var worldModel = WorldModel()

    var body: some Scene {
        WindowGroup {
            HQLobbyView(worldModel: worldModel)
        }
        .defaultSize(width: 500, height: 340)

        ImmersiveSpace(id: WorldModel.immersiveSpaceID) {
            HQImmersiveView(worldModel: worldModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
