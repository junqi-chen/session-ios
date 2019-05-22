import PromiseKit

@objc public final class LokiAPI : NSObject {
    private static let storage = OWSPrimaryStorage.shared()
    
    // MARK: Settings
    private static let version = "v1"
    public static let defaultMessageTTL: UInt64 = 1 * 24 * 60 * 60
    
    // MARK: Types
    internal struct Target : Hashable {
        let address: String
        let port: UInt16
        
        enum Method : String {
            /// Only applicable to snode targets.
            case getSwarm = "get_snodes_for_pubkey"
            /// Only applicable to snode targets.
            case getMessages = "retrieve"
            case sendMessage = "store"
        }
    }
    
    public typealias RawResponse = Any
    
    public enum Error : LocalizedError {
        /// Only applicable to snode targets as proof of work isn't required for P2P messaging.
        case proofOfWorkCalculationFailed
        
        public var errorDescription: String? {
            switch self {
            case .proofOfWorkCalculationFailed: return NSLocalizedString("Failed to calculate proof of work.", comment: "")
            }
        }
    }
    
    // MARK: Lifecycle
    override private init() { }
    
    // MARK: Internal API
    internal static func invoke(_ method: Target.Method, on target: Target, with parameters: [String:Any] = [:]) -> Promise<RawResponse> {
        let url = URL(string: "\(target.address):\(target.port)/\(version)/storage_rpc")!
        let request = TSRequest(url: url, method: "POST", parameters: [ "method" : method.rawValue, "params" : parameters ])
        return TSNetworkManager.shared().makePromise(request: request).map { $0.responseObject }
    }
    
    // MARK: Public API
    public static func getMessages() -> Promise<Set<Promise<[SSKProtoEnvelope]>>> {
        let hexEncodedPublicKey = OWSIdentityManager.shared().identityKeyPair()!.hexEncodedPublicKey
        return getTargetSnodes(for: hexEncodedPublicKey).mapValues { targetSnode in
            let lastHash = getLastMessageHashValue(for: targetSnode) ?? ""
            let parameters: [String:Any] = [ "pubKey" : hexEncodedPublicKey, "lastHash" : lastHash ]
            return invoke(.getMessages, on: targetSnode, with: parameters).map { rawResponse in
                guard let json = rawResponse as? JSON, let rawMessages = json["messages"] as? [JSON] else { return [] }
                updateLastMessageHashValueIfPossible(for: targetSnode, from: rawMessages)
                let newRawMessages = removeDuplicates(from: rawMessages)
                return parseProtoEnvelopes(from: newRawMessages)
            }
        }.map { Set($0) }
    }
    
    public static func sendSignalMessage(_ signalMessage: SignalMessage, to destination: String, timestamp: UInt64) -> Promise<Set<Promise<RawResponse>>> {
        let isP2PMessagingPossible = false
        return Message.from(signalMessage: signalMessage, timestamp: timestamp, requiringPoW: !isP2PMessagingPossible).then(sendMessage)
    }
    
    public static func sendMessage(_ lokiMessage: Message) -> Promise<Set<Promise<RawResponse>>> {
        let isP2PMessagingPossible = false
        if isP2PMessagingPossible {
            // TODO: Send using P2P protocol
        } else {
            let parameters = lokiMessage.toJSON()
            return getTargetSnodes(for: lokiMessage.destination).mapValues { invoke(.sendMessage, on: $0, with: parameters).recoverNetworkErrorIfNeeded(on: DispatchQueue.global()) }.map { Set($0) }
        }
    }
    
    public static func ping(_ hexEncodedPublicKey: String) -> Promise<Set<Promise<RawResponse>>> {
        let isP2PMessagingPossible = false
        if isP2PMessagingPossible {
            // TODO: Send using P2P protocol
        } else {
            let parameters: [String:Any] = [ "pubKey" : hexEncodedPublicKey ] // TODO: Figure out correct parameters
            return getTargetSnodes(for: hexEncodedPublicKey).mapValues { invoke(.sendMessage, on: $0, with: parameters).recoverNetworkErrorIfNeeded(on: DispatchQueue.global()) }.map { Set($0) }
        }
    }
    
    // MARK: Public API (Obj-C)
    @objc public static func objc_sendSignalMessage(_ signalMessage: SignalMessage, to destination: String, with timestamp: UInt64) -> AnyPromise {
        let promise = sendSignalMessage(signalMessage, to: destination, timestamp: timestamp).mapValues { AnyPromise.from($0) }.map { Set($0) }
        return AnyPromise.from(promise)
    }
    
    // MARK: Parsing
    
    // The parsing utilities below use a best attempt approach to parsing; they warn for parsing failures but don't throw exceptions.
    
    private static func updateLastMessageHashValueIfPossible(for target: Target, from rawMessages: [JSON]) {
        guard let lastMessage = rawMessages.last, let hashValue = lastMessage["hash"] as? String, let expiresAt = lastMessage["expiration"] as? Int else {
            Logger.warn("[Loki] Failed to update last message hash value from: \(rawMessages).")
            return
        }
        setLastMessageHashValue(for: target, hashValue: hashValue, expiresAt: UInt64(expiresAt))
    }
    
    private static func removeDuplicates(from rawMessages: [JSON]) -> [JSON] {
        var receivedMessageHashValues = getReceivedMessageHashValues() ?? []
        return rawMessages.filter { rawMessage in
            guard let hashValue = rawMessage["hash"] as? String else {
                Logger.warn("[Loki] Missing hash value for message: \(rawMessage).")
                return false
            }
            let isDuplicate = receivedMessageHashValues.contains(hashValue)
            receivedMessageHashValues.insert(hashValue)
            setReceivedMessageHashValues(to: receivedMessageHashValues)
            return !isDuplicate
        }
    }
    
    private static func parseProtoEnvelopes(from rawMessages: [JSON]) -> [SSKProtoEnvelope] {
        return rawMessages.compactMap { rawMessage in
            guard let base64EncodedData = rawMessage["data"] as? String, let data = Data(base64Encoded: base64EncodedData) else {
                Logger.warn("[Loki] Failed to decode data for message: \(rawMessage).")
                return nil
            }
            guard let envelope = try? LokiMessageWrapper.unwrap(data: data) else {
                Logger.warn("[Loki] Failed to unwrap data for message: \(rawMessage).")
                return nil
            }
            return envelope
        }
    }
    
    // MARK: Convenience
    private static func getLastMessageHashValue(for target: Target) -> String? {
        var result: String? = nil
        // Uses a read/write connection because getting the last message hash value also removes expired messages as needed
        storage.dbReadWriteConnection.readWrite { transaction in
            result = storage.getLastMessageHash(forServiceNode: target.address, transaction: transaction)
        }
        return result
    }
    
    private static func setLastMessageHashValue(for target: Target, hashValue: String, expiresAt: UInt64) {
        storage.dbReadWriteConnection.readWrite { transaction in
            storage.setLastMessageHash(forServiceNode: target.address, hash: hashValue, expiresAt: expiresAt, transaction: transaction)
        }
    }
    
    private static func getReceivedMessageHashValues() -> Set<String>? {
        var result: Set<String>? = nil
        storage.dbReadConnection.read { transaction in
            result = storage.getReceivedMessageHashes(with: transaction)
        }
        return result
    }
    
    private static func setReceivedMessageHashValues(to receivedMessageHashValues: Set<String>) {
        storage.dbReadWriteConnection.readWrite { transaction in
            storage.setReceivedMessageHashes(receivedMessageHashValues, with: transaction)
        }
    }
}

private extension AnyPromise {
    
    static func from<T : Any>(_ promise: Promise<T>) -> AnyPromise {
        let result = AnyPromise(promise)
        result.retainUntilComplete()
        return result
    }
}

// MARK: Error Handling
private extension Promise {

    func recoverNetworkErrorIfNeeded(on queue: DispatchQueue) -> Promise<T> {
        return recover(on: queue) { error -> Promise<T> in
            switch error {
            case NetworkManagerError.taskError(_, let underlyingError): throw underlyingError
            default: throw error
            }
        }
    }
}