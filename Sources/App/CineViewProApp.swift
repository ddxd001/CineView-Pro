//
//  CineViewProApp.swift
//  CineView Pro
//
//  App 入口：挂载 CineViewAppDelegate 以全局强制锁定横屏方向。
//

import SwiftUI

@main
struct CineViewProApp: App {
    @UIApplicationDelegateAdaptor(CineViewAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
