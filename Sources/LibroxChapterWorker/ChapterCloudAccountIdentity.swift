import Foundation
import CryptoKit

/// Host obtains the actual container account ID and signed CloudKit environment
/// before deriving this partition. Do not infer environment from DEBUG or APS.
/// The raw user record name is hashed and is never retained or exposed here.
public struct ChapterCloudAccountIdentity: Sendable, Equatable {
    public enum Environment: String, Sendable { case development, production }
    public let containerIdentifier: String
    public let environment: Environment
    public let accountPartition: String

    public init(containerIdentifier: String, environment: Environment, userRecordName: String) throws {
        guard containerIdentifier.hasPrefix("iCloud."), containerIdentifier.utf8.count <= 256,
              !userRecordName.isEmpty, userRecordName.utf8.count <= 1024,
              [containerIdentifier, userRecordName].allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        else { throw ChapterWorkerError.invalidIdentity }
        struct Identity: Encodable {
            let version, container, environment, database, zone, account: String
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Identity(version: "librox-chapter-cloud-1", container: containerIdentifier,
            environment: environment.rawValue, database: "private", zone: ChapterCloudDemandTransport.zoneName, account: userRecordName))
        self.containerIdentifier = containerIdentifier; self.environment = environment
        accountPartition = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
