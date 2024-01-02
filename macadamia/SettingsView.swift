//
//  SettingView.swift
//  macadamia
//
//  Created by Dario Lass on 13.12.23.
//

import SwiftUI

struct SettingsView: View {
    
    var appVersion:String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink(destination: MintManagerView()) { Text("Mints") }
                    NavigationLink(destination: Text("Show Seed Phrase")) { Text("Show Seed Phrase") }
                    NavigationLink(destination: Text("Restore")) { Text("Restore") }
                } header: {
                    Text("cashu")
                }
                Section {
                    NavigationLink(destination: RelayManagerView()) { Text("Relays") }
                    } header: {
                        Text("nostr")
                    }
                Section {
                    NavigationLink(destination: Text("Acknowledgments")) { Text("View source on Github") }
                    NavigationLink(destination: Text("Acknowledgments")) { Text("Acknowledgments") }
                } header: {
                    Text("Information")
                } footer: {
                    Text("macadamia, \(appVersion)")
                        .font(.system(size: 16)) // Adjust the size as needed
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .navigationTitle("Settings")
        }
    }
}


#Preview {
    SettingsView()
}
