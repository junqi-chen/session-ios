import PromiseKit

/// Base class for `LokiStorageAPI` and `LokiPublicChatAPI`.
public class LokiDotNetAPI : NSObject {

    // MARK: Convenience
    internal static let storage = OWSPrimaryStorage.shared()
    internal static let userKeyPair = OWSIdentityManager.shared().identityKeyPair()!
    internal static let userHexEncodedPublicKey = userKeyPair.hexEncodedPublicKey

    // MARK: Settings
    private static let attachmentType = "network.loki"
    
    // MARK: Error
    public enum Error : Swift.Error {
        case generic, parsingFailed, encryptionFailed, decryptionFailed, signingFailed
    }

    // MARK: Database
    /// To be overridden by subclasses.
    internal class var authTokenCollection: String { preconditionFailure("authTokenCollection is abstract and must be overridden.") }

    private static func getAuthTokenFromDatabase(for server: String) -> String? {
        var result: String? = nil
        storage.dbReadConnection.read { transaction in
            result = transaction.object(forKey: server, inCollection: authTokenCollection) as! String?
        }
        return result
    }

    private static func setAuthToken(for server: String, to newValue: String) {
        storage.dbReadWriteConnection.readWrite { transaction in
            transaction.setObject(newValue, forKey: server, inCollection: authTokenCollection)
        }
    }

    // MARK: Lifecycle
    override private init() { }

    // MARK: Attachments (Public API)
    public static func uploadAttachment(_ attachment: TSAttachmentStream, with attachmentID: String, to server: String) -> Promise<Void> {
        let isEncryptionRequired = (server == LokiStorageAPI.server)
        return Promise<Void>() { seal in
            func proceed(with token: String) {
                // Get the attachment
                let data: Data
                guard let unencryptedAttachmentData = try? attachment.readDataFromFile() else {
                    print("[Loki] Couldn't read attachment from disk.")
                    return seal.reject(Error.generic)
                }
                // Encrypt the attachment if needed
                if isEncryptionRequired {
                    var encryptionKey = NSData()
                    var digest = NSData()
                    guard let encryptedAttachmentData = Cryptography.encryptAttachmentData(unencryptedAttachmentData, outKey: &encryptionKey, outDigest: &digest) else {
                        print("[Loki] Couldn't encrypt attachment.")
                        return seal.reject(Error.encryptionFailed)
                    }
                    attachment.encryptionKey = encryptionKey as Data
                    attachment.digest = digest as Data
                    data = encryptedAttachmentData
                } else {
                    data = unencryptedAttachmentData
                }
                // Create the request
                let url = "\(server)/files"
                let parameters: JSON = [ "type" : attachmentType, "Content-Type" : "application/binary" ]
                var error: NSError?
                var request = AFHTTPRequestSerializer().multipartFormRequest(withMethod: "POST", urlString: url, parameters: parameters, constructingBodyWith: { formData in
                    formData.appendPart(withFileData: data, name: "content", fileName: UUID().uuidString, mimeType: "application/binary")
                }, error: &error)
                request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let error = error {
                    print("[Loki] Couldn't upload attachment due to error: \(error).")
                    return seal.reject(error)
                }
                // Send the request
                func parseResponse(_ response: Any) {
                    // Parse the server ID & download URL
                    guard let json = response as? JSON, let data = json["data"] as? JSON, let serverID = data["id"] as? UInt64, let downloadURL = data["url"] as? String else {
                        print("[Loki] Couldn't parse attachment from: \(response).")
                        return seal.reject(Error.parsingFailed)
                    }
                    // Update the attachment
                    attachment.serverId = serverID
                    attachment.isUploaded = true
                    attachment.downloadURL = downloadURL
                    attachment.save()
                    seal.fulfill(())
                }
                let isProxyingRequired = (server == LokiStorageAPI.server) // Don't proxy open group requests for now
                if isProxyingRequired {
                    let _ = LokiFileServerProxy(for: server).performLokiFileServerNSURLRequest(request as NSURLRequest).done { responseObject in
                        parseResponse(responseObject)
                    }.catch { error in
                        seal.reject(error)
                    }
                } else {
                    let task = AFURLSessionManager(sessionConfiguration: .default).uploadTask(withStreamedRequest: request as URLRequest, progress: { rawProgress in
                        // Broadcast progress updates
                        let progress = max(0.1, rawProgress.fractionCompleted)
                        let userInfo: [String:Any] = [ kAttachmentUploadProgressKey : progress, kAttachmentUploadAttachmentIDKey : attachmentID ]
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .attachmentUploadProgress, object: nil, userInfo: userInfo)
                        }
                    }, completionHandler: { response, responseObject, error in
                        if let error = error {
                            print("[Loki] Couldn't upload attachment due to error: \(error).")
                            return seal.reject(error)
                        }
                        let statusCode = (response as! HTTPURLResponse).statusCode
                        let isSuccessful = (200...299) ~= statusCode
                        guard isSuccessful else {
                            print("[Loki] Couldn't upload attachment.")
                            return seal.reject(Error.generic)
                        }
                        parseResponse(responseObject)
                    })
                    task.resume()
                }
            }
            if server == LokiStorageAPI.server {
                proceed(with: "loki") // Uploads to the Loki File Server shouldn't include any personally identifiable information so use a dummy auth token
            } else {
                getAuthToken(for: server).done(on: DispatchQueue.global()) { token in
                    proceed(with: token)
                }.catch(on: DispatchQueue.global()) { error in
                    print("[Loki] Couldn't upload attachment due to error: \(error).")
                    seal.reject(error)
                }
            }
        }
    }
    
    // MARK: Internal API
    internal static func getAuthToken(for server: String) -> Promise<String> {
        if let token = getAuthTokenFromDatabase(for: server) {
            return Promise.value(token)
        } else {
            return requestNewAuthToken(for: server).then(on: DispatchQueue.global()) { submitAuthToken($0, for: server) }.map { token -> String in
                setAuthToken(for: server, to: token)
                return token
            }
        }
    }

    // MARK: Private API
    private static func requestNewAuthToken(for server: String) -> Promise<String> {
        print("[Loki] Requesting auth token for server: \(server).")
        let queryParameters = "pubKey=\(userHexEncodedPublicKey)"
        let url = URL(string: "\(server)/loki/v1/get_challenge?\(queryParameters)")!
        let request = TSRequest(url: url)
        return LokiFileServerProxy(for: server).perform(request, withCompletionQueue: DispatchQueue.global()).map { rawResponse in
            guard let json = rawResponse as? JSON, let base64EncodedChallenge = json["cipherText64"] as? String, let base64EncodedServerPublicKey = json["serverPubKey64"] as? String,
                let challenge = Data(base64Encoded: base64EncodedChallenge), var serverPublicKey = Data(base64Encoded: base64EncodedServerPublicKey) else {
                throw Error.parsingFailed
            }
            // Discard the "05" prefix if needed
            if serverPublicKey.count == 33 {
                let hexEncodedServerPublicKey = serverPublicKey.toHexString()
                serverPublicKey = Data.data(fromHex: hexEncodedServerPublicKey.substring(from: 2))!
            }
            // The challenge is prefixed by the 16 bit IV
            guard let tokenAsData = try? DiffieHellman.decrypt(challenge, publicKey: serverPublicKey, privateKey: userKeyPair.privateKey),
                let token = String(bytes: tokenAsData, encoding: .utf8) else {
                throw Error.decryptionFailed
            }
            return token
        }
    }

    private static func submitAuthToken(_ token: String, for server: String) -> Promise<String> {
        print("[Loki] Submitting auth token for server: \(server).")
        let url = URL(string: "\(server)/loki/v1/submit_challenge")!
        let parameters = [ "pubKey" : userHexEncodedPublicKey, "token" : token ]
        let request = TSRequest(url: url, method: "POST", parameters: parameters)
        return LokiFileServerProxy(for: server).perform(request, withCompletionQueue: DispatchQueue.global()).map { _ in token }
    }
    
    // MARK: Attachments (Public Obj-C API)
    @objc(uploadAttachment:withID:toServer:)
    public static func objc_uploadAttachment(_ attachment: TSAttachmentStream, with attachmentID: String, to server: String) -> AnyPromise {
        return AnyPromise.from(uploadAttachment(attachment, with: attachmentID, to: server))
    }
}
