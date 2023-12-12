import Foundation
import CryptoKit
import secp256k1
import BIP39

class Wallet {
    
    enum WalletError: Error {
        case invalidMnemonicError
        case tokenDeserializationError
        case tokenSerializationError(detail:String)
        case unknownMintError //TODO: should not be treated like an error
        case missingMintKeyset
        case insufficientFunds(mint:Mint)
    }
    
    var database = Database.loadFromFile() //TODO: set to private
    
    init(database: Database = Database.loadFromFile()) {
        self.database = database
        
        if self.database.mnemonic == nil {
            let randomMnemonic = Mnemonic()
            self.database.mnemonic = randomMnemonic.phrase.joined(separator: " ")
            self.database.seed = String(bytes: randomMnemonic.seed)
            self.database.saveToFile()
        }
    }
    
    func updateMints() async throws {
        
        //add default mint
        if self.database.mints.isEmpty {
            let url = URL(string: "https://8333.space:3338")!
            let m = Mint(url: url, activeKeyset: nil, allKeysets: nil)
            self.database.mints.append(m)
            
        }
                
        for mint in self.database.mints {
            guard let allKeysetIDs = try? await Network.loadAllKeysetIDs(mintURL: mint.url) else {
                print("could not get all keyset IDs")
                continue
            }
            guard let activeKeysetDict = try? await Network.loadKeyset(mintURL: mint.url, keysetID: nil) else {
                print("could not load current keyset of mint \(mint.url)")
                continue
            }
            print(allKeysetIDs)
            mint.allKeysets = []
            for id in allKeysetIDs.keysets {
                guard let keysetDict = try? await Network.loadKeyset(mintURL: mint.url, keysetID: id) else {
                    print("could not get keyset with \(id) of mint \(mint.url)")
                    continue
                }
                let keyset = Keyset(id: id, keys: keysetDict)
                mint.allKeysets!.append(keyset)
                if keysetDict == activeKeysetDict {
                    mint.activeKeyset = keyset
                }
            }
        }
        self.database.saveToFile()
        
    }
    
    //MARK: - Mint
    func getQuote(from mint:Mint,for amount:Int) async throws -> QuoteRequestResponse {
        let quote = try await Network.requestQuote(for: amount, from: mint)
        return quote
    }
    
    func requestMint(from mint:Mint, for quote:QuoteRequestResponse, with amount:Int) async throws {
        let (outputs, bfs, secrets) = generateDeterministicOutputs(counter: self.database.secretDerivationCounter, seed: self.database.seed!, amounts: splitIntoBase2Numbers(n: amount), keysetID: mint.activeKeyset!.id)
        let promises = try await Network.requestSignature(mint: mint, outputs: outputs, amount: amount, invoiceHash: quote.hash)
        let proofs = unblindPromises(promises: promises, blindingFactors: bfs, secrets: secrets, mintPublicKeys: mint.activeKeyset!.keys!)
        database.proofs.append(contentsOf: proofs)
        database.secretDerivationCounter += proofs.count
        database.saveToFile()
    }
    
    //MARK: Send
    func sendTokens(from mint:Mint, amount:Int) async throws -> String {
        let (proofs, sum) = try database.retrieveProofs(from: mint, amount: amount)
        if amount == sum {
            self.database.removeProofsFromValid(proofsToRemove: proofs)
            self.database.saveToFile()
            return try serializeProofs(proofs: proofs)
        } else if amount < sum {
            let toSend = splitIntoBase2Numbers(n: amount)
            let rest = splitIntoBase2Numbers(n: sum-amount)
            let combined = (toSend+rest).sorted()
            let (outputs, bfs, secrets) = generateDeterministicOutputs(counter: database.secretDerivationCounter,
                                                                       seed: database.seed!,
                                                                       amounts: combined,
                                                                       keysetID: mint.activeKeyset!.id)
            let newPromises = try await Network.split(for: mint, proofs: proofs, outputs: outputs)
            guard let keys = mint.activeKeyset?.keys else {
                throw WalletError.missingMintKeyset
            }
            var newProofs = unblindPromises(promises: newPromises, blindingFactors: bfs, secrets: secrets, mintPublicKeys: keys)
            var sendProofs = [Proof]()
            for n in toSend {
                if let index = newProofs.firstIndex(where: {$0.amount == n}) {
                    sendProofs.append(newProofs[index])
                    newProofs.remove(at: index)
                }
            }
            database.removeProofsFromValid(proofsToRemove: proofs)
            database.proofs.append(contentsOf: newProofs)
            database.secretDerivationCounter += outputs.count
            database.saveToFile()
            return try serializeProofs(proofs: sendProofs)
        } else {
            throw WalletError.unknownMintError
        }
    }
    
    //MARK: - Receive
    func receiveToken(tokenString:String) async throws {
        let tokenlist = try self.deserializeToken(token: tokenString)
        var amounts = [Int]()
        for p in tokenlist[0].proofs {
            amounts.append(p.amount)
        }
        guard let mint = self.database.mintForKeysetID(id: tokenlist[0].proofs[0].id) else {
            throw WalletError.unknownMintError
        }
        guard let keyset = mint.activeKeyset,
              keyset.keys != nil else {
            throw WalletError.missingMintKeyset
        }
        let (newOutputs, bfs, secrets) = generateDeterministicOutputs(counter: self.database.secretDerivationCounter,
                                                      seed: database.seed!,
                                                      amounts: amounts,
                                                      keysetID: keyset.id)
        let newPromises = try await Network.split(for: mint, proofs: tokenlist[0].proofs, outputs: newOutputs)
        let newProofs = unblindPromises(promises: newPromises, blindingFactors: bfs, secrets: secrets, mintPublicKeys: keyset.keys!)
        self.database.proofs.append(contentsOf: newProofs)
        self.database.secretDerivationCounter += newProofs.count
        self.database.saveToFile()
    }
    
    //MARK: - Melt
    func melt(mint:Mint, invoice:String, completion: @escaping (Result<Void,Error>) -> Void) {
        // 1. check fee (maybe again)
        // 2. determine invoice amnt
        // 3. retrieve proofs from db for amount + fee
        // 4. TODO: implement change proofs for melting, FIX HORRIBLE NESTING
        
        Network.checkFee(mint: mint, invoice: invoice) { checkFeeResult in
            switch checkFeeResult {
            case .success(let fee):
                if let invoiceAmount = QuoteRequestResponse.satAmountFromInvoice(pr: invoice) {
                    let total = invoiceAmount + fee
                    if let (proofs, sum) = try? self.database.retrieveProofs(from: mint, amount: total) {
                        Network.meltRequest(mint: mint, meltRequest: MeltRequest(proofs: proofs, pr: invoice)) { meltRequestResult in
                            switch meltRequestResult {
                            case .success():
                                self.database.removeProofsFromValid(proofsToRemove: proofs)
                                self.database.saveToFile()
                                completion(.success(()))
                            case .failure(let meltError):
                                completion(.failure(meltError))
                            }
                        }
                    } else {
                        print("did not receive (enough) proofs for melting tokens")
                    }
                } else {
                    //FIXME: needs correct error type
                    completion(.failure(NetworkError.decodingError))
                }
            case .failure(let error):
                print(error)
            }
        }
    }
        
    //MARK: - Restore
    func restoreWithMnemonic(mnemonic:String) async throws {
        
        // reset database
        guard let newMnemonic = try? BIP39.Mnemonic(phrase: mnemonic.components(separatedBy: .whitespacesAndNewlines)) else {
            throw WalletError.invalidMnemonicError
        }
        
        self.database = Database(mnemonic: mnemonic, secretDerivationCounter: 0)
        self.database.seed = String(bytes: newMnemonic.seed)
        self.database.mints.append(Mint(url: URL(string: "https://mint.zeugmaster.com:3338")!, activeKeyset: nil, allKeysets: nil))
        try await updateMints()
        self.database.saveToFile() //overrides existing
        for mint in database.mints {
            for keyset in mint.allKeysets! {
                let responsetuple = await restoreProofs(mint: mint, keysetID: keyset.id, seed: self.database.seed!)
                self.database.proofs.append(contentsOf: responsetuple.proofs)
                self.database.secretDerivationCounter = responsetuple.lastMatchCounter
                self.database.saveToFile()
                print(responsetuple)
            }
        }
    }
    
    private func restoreProofs(mint:Mint, keysetID:String, seed:String, batchSize:Int = 10) async -> (proofs:[Proof], totalRestored:Int, lastMatchCounter:Int) {
        
        guard let mintPubkeys = mint.allKeysets?.first(where: {$0.id == keysetID})?.keys else {
            print("ERROR: could not find public keys for keyset: \(keysetID)")
            return ([], 0, 0) //FIXME: should be error handling instead
        }
        var proofs = [Proof]()
        var emtpyResponses = 0
        var currentCounter = 0
        var batchLastMatchIndex = 0
        let emptyRuns = 2
        while emtpyResponses < emptyRuns {
            print(keysetID)
            let (outputs, blindingFactors, secrets) = generateDeterministicOutputs(counter: currentCounter,
                                                                                   seed: self.database.seed!,
                                                                                   amounts: Array(repeating: 1, count: batchSize),
                                                                                   keysetID: keysetID)
            
            guard let restoreRespone = try? await Network.restoreRequest(mintURL: mint.url, outputs: outputs) else {
                print("unable to decode restoreResponse from Mint")
                return ([], 0, 0)
            }
            print(restoreRespone)
            currentCounter += batchSize
            //currentcounter needs to be correct
            batchLastMatchIndex = outputs.lastIndex(where: { oldOutput in
                restoreRespone.outputs.contains(where: {newOut in oldOutput.B_ == newOut.B_})
            }) ?? 0
            
            if restoreRespone.promises.isEmpty {
                emtpyResponses += 1
                continue
            } else {
                //reset counter to ensure they are CONSECUTIVE empty responses
                emtpyResponses = 0
            }
            var rs = [String]()
            var xs = [String]()
            for i in 0..<outputs.count {
                if restoreRespone.outputs.contains(where: {$0.B_ == outputs[i].B_}) {
                    rs.append(blindingFactors[i])
                    xs.append(secrets[i])
                }
            }
            
            let batchProofs = unblindPromises(promises: restoreRespone.promises, blindingFactors: rs, secrets: xs, mintPublicKeys: mintPubkeys)
            proofs.append(contentsOf: batchProofs)
            print("current counter: \(currentCounter), emptyruns: \(emptyRuns), batchlastmatch:\(batchLastMatchIndex)")
        }
        currentCounter -= emptyRuns * batchSize
        currentCounter += batchLastMatchIndex
        
        return (proofs, currentCounter, proofs.count)
    }

    //MARK: - HELPERS
    private func serializeProofs(proofs: [Proof]) throws -> String {
        guard let mint = database.mintForKeysetID(id: proofs[0].id) else {
            throw WalletError.tokenSerializationError(detail: "no mint found for keyset id: \(proofs[0].id)")
        }
        let token = Token_JSON(mint: mint.url.absoluteString, proofs: proofs)
        let tokenContainer = Token_Container(token: [token], memo: "...fiat esse delendam.")
        let jsonData = try JSONEncoder().encode(tokenContainer)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        let safeString = Base64FS.encodeString(str: jsonString)
        return "cashuA" + safeString
    }
    
    private func deserializeToken(token: String) throws -> [Token_JSON] {
        //TODO: check for more cases where invalid
        let noPrefix = token.dropFirst(6)
        let jsonString = Base64FS.decodeString(str: String(noPrefix))
        print(jsonString)
        let jsonData = jsonString.data(using: .utf8)!
        guard let tokenContainer:Token_Container = try? JSONDecoder().decode(Token_Container.self, from: jsonData) else {
            throw WalletError.tokenDeserializationError
        }
        return tokenContainer.token
    }

    func splitIntoBase2Numbers(n: Int) -> [Int] {
        var remaining = n
        var result: [Int] = []
        while remaining > 0 {
            var powerOfTwo = 1
            while (powerOfTwo * 2) <= remaining {
                powerOfTwo *= 2
            }
            remaining -= powerOfTwo
            result.append(powerOfTwo)
        }
        return result
    }
}


