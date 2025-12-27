//
//  FfmpegArcanaCamApp.swift
//  FfmpegArcanaCam
//
//  Created by rich insley on 12/27/25.
//

import SwiftUI

@main
struct FfmpegArcanaCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraPreviewView()  // Changed from ContentView
        }
    }
}
