//
//  HQLobbyView.swift
//  LoopHQ
//
//  A small 2D window that acts as the entry point. The user taps
//  "Enter HQ" to open the fully immersive Salesforce Park world.
//

import SwiftUI

struct HQLobbyView: View {

    let worldModel: WorldModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 24) {
            Text("Loop HQ")
                .font(.system(size: 42, weight: .bold, design: .rounded))

            Text("Salesforce Park · San Francisco")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("A multiplayer, walkable photoreal world.\nPinch left hand to move · Pinch right hand to look.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)

            Button {
                Task { await enter() }
            } label: {
                Label("Enter HQ", systemImage: "globe.americas.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(worldModel.phase != .lobby)

            if worldModel.phase == .loading {
                ProgressView(worldModel.statusMessage)
            }
        }
        .padding(40)
    }

    private func enter() async {
        worldModel.beginLoading()
        let result = await openImmersiveSpace(id: WorldModel.immersiveSpaceID)
        switch result {
        case .opened:
            worldModel.enterWorld()
        case .error, .userCancelled:
            worldModel.returnToLobby()
        @unknown default:
            worldModel.returnToLobby()
        }
    }
}
