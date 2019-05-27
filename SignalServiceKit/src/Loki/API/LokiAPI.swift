import PromiseKit

@objc public final class LokiAPI : NSObject {
    internal static let storage = OWSPrimaryStorage.shared()
    
    // MARK: Settings
    private static let version = "v1"
    private static let maxRetryCount: UInt = 3
    public static let defaultMessageTTL: UInt64 = 1 * 24 * 60 * 60 * 1000
    
    // MARK: Types
    public typealias RawResponse = Any
    
    public enum Error : LocalizedError {
        /// Only applicable to snode targets as proof of work isn't required for P2P messaging.
        case proofOfWorkCalculationFailed
        case messageConversionFailed
        
        public var errorDescription: String? {
            switch self {
            case .proofOfWorkCalculationFailed: return NSLocalizedString("Failed to calculate proof of work.", comment: "")
            case .messageConversionFailed: return "Failed to convert Signal message to Loki message."
            }
        }
    }
    
    public typealias MessagePromise = Promise<[SSKProtoEnvelope]> // To keep the return type of getMessages() readable
    
    // MARK: Lifecycle
    override private init() { }
    
    // MARK: Internal API
    internal static func invoke(_ method: Target.Method, on target: Target, associatedWith hexEncodedPublicKey: String, parameters: [String:Any] = [:]) -> Promise<RawResponse> {
        let url = URL(string: "\(target.address):\(target.port)/\(version)/storage_rpc")!
        let request = TSRequest(url: url, method: "POST", parameters: [ "method" : method.rawValue, "params" : parameters ])
        return TSNetworkManager.shared().makePromise(request: request).map { $0.responseObject }
            .handlingSwarmSpecificErrorsIfNeeded(for: target, associatedWith: hexEncodedPublicKey).recoveringNetworkErrorsIfNeeded()
    }
    
    // MARK: Public API
    public static func getMessages() -> Promise<Set<MessagePromise>> {
        let hexEncodedPublicKey = OWSIdentityManager.shared().identityKeyPair()!.hexEncodedPublicKey
        return getTargetSnodes(for: hexEncodedPublicKey).mapValues { targetSnode in
            let lastHash = getLastMessageHashValue(for: targetSnode) ?? ""
            let parameters: [String:Any] = [ "pubKey" : hexEncodedPublicKey, "lastHash" : lastHash ]
            return invoke(.getMessages, on: targetSnode, associatedWith: hexEncodedPublicKey, parameters: parameters).map { rawResponse in
                guard let json = rawResponse as? JSON, let rawMessages = json["messages"] as? [JSON] else { return [] }
                updateLastMessageHashValueIfPossible(for: targetSnode, from: rawMessages)
                let newRawMessages = removeDuplicates(from: rawMessages)
                return parseProtoEnvelopes(from: newRawMessages)
            }
        }.map { Set($0) }.retryingIfNeeded(maxRetryCount: maxRetryCount)
    }
    
    public static func sendSignalMessage(_ signalMessage: SignalMessage, to destination: String, with timestamp: UInt64) -> Promise<Set<Promise<RawResponse>>> {
        guard let lokiMessage = Message.from(signalMessage: signalMessage, with: timestamp) else { return Promise(error: Error.messageConversionFailed) }
        let destination = lokiMessage.destination
        func sendLokiMessage(_ lokiMessage: Message, to target: Target) -> Promise<RawResponse> {
            let parameters = lokiMessage.toJSON()
            return invoke(.sendMessage, on: target, associatedWith: destination, parameters: parameters)
        }
        func sendLokiMessageUsingSwarmAPI() -> Promise<Set<Promise<RawResponse>>> {
            let powPromise = lokiMessage.calculatePoW()
            let swarmPromise = getTargetSnodes(for: destination)
            return when(fulfilled: powPromise, swarmPromise).map { lokiMessageWithPoW, swarm in
                return Set(swarm.map { sendLokiMessage(lokiMessageWithPoW, to: $0) })
            }
        }
        if let p2pDetails = LokiP2PManager.getDetails(forContact: destination), (lokiMessage.isPing || p2pDetails.isOnline) {
            return Promise.value([ p2pDetails.target ]).mapValues { sendLokiMessage(lokiMessage, to: $0) }.map { Set($0) }.retryingIfNeeded(maxRetryCount: maxRetryCount).get { _ in
                LokiP2PManager.setOnline(true, forContact: destination)
            }.recover { error -> Promise<Set<Promise<RawResponse>>> in
                LokiP2PManager.setOnline(false, forContact: destination)
                if lokiMessage.isPing {
                    Logger.warn("[Loki] Failed to ping \(destination); marking contact as offline.")
                    if let nsError = error as? NSError {
                        nsError.isRetryable = false
                        throw nsError
                    } else {
                        throw error
                    }
                }
                return sendLokiMessageUsingSwarmAPI().retryingIfNeeded(maxRetryCount: maxRetryCount)
            }
        } else {
            return sendLokiMessageUsingSwarmAPI().retryingIfNeeded(maxRetryCount: maxRetryCount)
        }
    }
    
    // MARK: Public API (Obj-C)
    @objc public static func objc_sendSignalMessage(_ signalMessage: SignalMessage, to destination: String, with timestamp: UInt64) -> AnyPromise {
        let promise = sendSignalMessage(signalMessage, to: destination, with: timestamp).mapValues { AnyPromise.from($0) }.map { Set($0) }
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
}
