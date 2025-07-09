//
//  Bulk_PDF_DecryptApp.swift
//  Bulk PDF Decrypt
//
//  Created by Wool Magnet on 7/8/25.
//

import SwiftUI
import SwiftData

@main
struct Bulk_PDF_DecryptApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
