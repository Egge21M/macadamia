//
//  MintManagerView.swift
//  macadamia
//
//  Created by Dario Lass on 01.01.24.
//

import SwiftUI

let previewList = [Mint(url: URL(string: "https://8333.space:3338")!, activeKeyset: Keyset(id: "", keys: ["":""], derivationCounter: 0), allKeysets: [], info: MintInfo(name: "", pubkey: "", version: "", contact: [[]], nuts: [], parameter: ["":false])),
                   Mint(url: URL(string: "https://test.space:3338")!, activeKeyset: Keyset(id: "", keys: ["":""], derivationCounter: 0), allKeysets: [], info: MintInfo(name: "", pubkey: "", version: "", contact: [[]], nuts: [], parameter: ["":false])),
                   Mint(url: URL(string: "https://zeugmaster.com:3338")!, activeKeyset: Keyset(id: "", keys: ["":""], derivationCounter: 0), allKeysets: [], info: MintInfo(name: "", pubkey: "", version: "", contact: [[]], nuts: [], parameter: ["":false]))]



struct MintManagerView: View {
    @ObservedObject var vm = MintManagerViewModel()
    
    var body: some View {
        List {
            Section {
                ForEach(vm.mintList, id: \.url) { mint in
                    HStack {
                        Circle()
                            .foregroundColor(.green)
                            .frame(width: 10, height: 8)
                        Text(mint.url.absoluteString)
                    }
                }
                .onDelete(perform: { indexSet in
                    vm.removeMint(at:indexSet)
                })
                TextField("enter new Mint URL", text: $vm.newMintURLString)
                    .onSubmit {vm.addMintWithUrlString() }
            } footer: {
                Text("Swipe to delete. Make sure to add correct prefix and port numbers to mint URLs.")
            }
        }
        .alert(vm.currentAlert?.title ?? "Error", isPresented: $vm.showAlert) {
            Button(role: .cancel) {
                
            } label: {
                Text(vm.currentAlert?.primaryButtonText ?? "OK")
            }
            if vm.currentAlert?.onAffirm != nil &&
                vm.currentAlert?.affirmText != nil {
                Button(role: .destructive) {
                    vm.currentAlert!.onAffirm!()
                } label: {
                    Text(vm.currentAlert!.affirmText!)
                }
            }
        } message: {
            Text(vm.currentAlert?.alertDescription ?? "")
        }
    }
}

@MainActor
class MintManagerViewModel: ObservableObject {
    @Published var mintList = [Mint]()
    @Published var error:Error?
    @Published var newMintURLString = ""
    
    @Published var showAlert:Bool = false
    var currentAlert:AlertDetail?
    
    var wallet = Wallet.shared
    
    struct AlertDetail {
        let title:String
        let alertDescription:String?
        let primaryButtonText:String?
        let affirmText:String?
        let onAffirm:(() -> Void)?
        
        init(title: String,
             description: String? = nil,
             primaryButtonText: String? = nil,
             affirmText: String? = nil,
             onAffirm: (() -> Void)? = nil) {
            
            self.title = title
            self.alertDescription = description
            self.primaryButtonText = primaryButtonText
            self.affirmText = affirmText
            self.onAffirm = onAffirm
        }
    }
    
    init() {
        self.mintList = wallet.database.mints
    }
    
    func addMintWithUrlString() {
        // needs to check for uniqueness and URL format
        guard let url = URL(string: newMintURLString),
            newMintURLString.contains("https://") else {
            newMintURLString = ""
            displayAlert(alert: AlertDetail(title: "Invalid URL", 
                                            description: "The URL you entered was not valid. Make sure it uses correct formatting as well as the right prefix."))
            return
        }
        
        guard !mintList.contains(where: { $0.url.absoluteString == newMintURLString }) else {
            displayAlert(alert: AlertDetail(title: "Already added.",
                                           description: "This URL is already in the list of knowm mints, please choose another one."))
            newMintURLString = ""
            return
        }
        
        Task {
            do {
                try await wallet.addMint(with:url)
                mintList = wallet.database.mints
                newMintURLString = ""
            } catch {
                displayAlert(alert: AlertDetail(title: "Could not be added",
                                                description: "The mint with this URL could not be added. \(error)"))
                newMintURLString = ""
            }
        }
        
        print(newMintURLString)
    }
    
    func removeMint(at offsets: IndexSet) {
        
        //TODO: check mint balance
        //https://mint.zeugmaster.com:3338
        if true {
            displayAlert(alert: AlertDetail(title: "Are you sure?",
                                           description: "This mint still has a balance. Are you sure you want to delete it?",
                                            primaryButtonText: "Cancel",
                                           affirmText: "Yes",
                                            onAffirm: {
                print("LFFFG")
                self.mintList.remove(atOffsets: offsets)
                //TODO: REMOVE FROM ACTUAL DATABASE
            }))
        }
    }
    
    private func displayAlert(alert:AlertDetail) {
        currentAlert = alert
        showAlert = true
    }
}

#Preview {
    MintManagerView()
}