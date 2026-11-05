import CloudKit
import Foundation
import Testing
@testable import LibroxChatterboxPlanning

@Suite struct CloudLibraryTests {
    @Test func projectsExistingLibroxMirrorWithoutInventingDeviceOrigin() throws {
        let record = CKRecord(recordType: "CD_StoredBook", recordID: .init(recordName: "one", zoneID: .init(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)))
        record["CD_title"] = "A book"; record["CD_formatRaw"] = "epub"
        record["CD_id"] = "original-library-id"; record["CD_author"] = "An author"
        record["CD_progressPercent"] = NSNumber(value: 0.42)
        record["CD_lastOpened"] = Date(timeIntervalSince1970: 100) as CKRecordValue
        let book = try #require(ChatterboxCloudLibraryBook(record))
        #expect(book.libraryID == "original-library-id")
        #expect(book.title == "A book"); #expect(book.author == "An author")
        #expect(book.progress == 0.42); #expect(book.canPrepare)
        #expect(book.lastOpened == Date(timeIntervalSince1970: 100))
    }
    @Test func ignoresOtherEntitiesAndBoundsLegacyProgress() throws {
        #expect(ChatterboxCloudLibraryBook(CKRecord(recordType: "CD_Annotation")) == nil)
        let record = CKRecord(recordType: "CD_StoredBook")
        record["CD_title"] = ""; record["CD_formatRaw"] = "pdf"
        record["CD_progressPercent"] = NSNumber(value: Double.infinity)
        let book = try #require(ChatterboxCloudLibraryBook(record))
        #expect(!book.canPrepare); #expect(book.progress == 0)
        #expect(book.title == "Untitled Book"); #expect(book.lastOpened == nil)
    }
}
