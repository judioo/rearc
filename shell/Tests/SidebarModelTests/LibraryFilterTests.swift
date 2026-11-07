import Foundation
import Testing
@testable import SidebarModel

struct LibraryFilterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func record(_ name: String = "report.pdf", state: DownloadState = .complete, mime: String = "", danger: UInt32 = 0) -> DownloadRecord {
        DownloadRecord(id: name, source: .chromium, url: "https://files.test/\(name)", mimeType: mime,
                       state: state, dangerType: danger, startedAt: now)
    }

    @Test func statesIncludePausedFailuresAndSafetyWarnings() {
        var filter = LibraryDownloadFilter()
        #expect(!filter.isActive)
        filter.state = .failed
        #expect(filter.includes(record(state: .interrupted), now: now))
        #expect(filter.includes(record(state: .cancelled), now: now))
        #expect(!filter.includes(record(), now: now))
        filter.state = .inProgress
        var paused = record(state: .inProgress)
        paused.isPaused = true
        #expect(filter.includes(paused, now: now))
        filter.state = .dangerous
        #expect(filter.includes(record(state: .inProgress, danger: 2), now: now))
        #expect(!filter.includes(record(state: .inProgress, danger: 6), now: now))
        let insecure = DownloadWarning(dangerType: 0, insecureStatus: 3, isDangerous: false, isInsecure: true)
        #expect(filter.includes(record(), warning: insecure, now: now))
        let safe = DownloadWarning(dangerType: 6, insecureStatus: 2, isDangerous: false, isInsecure: false)
        #expect(!filter.includes(record(danger: 2), warning: safe, now: now))
    }

    @Test func typesUseMimeOrCaseInsensitiveFileExtension() {
        #expect(LibraryDownloadType.documents.includes(record("REPORT.PDF")))
        #expect(LibraryDownloadType.documents.includes(record("download", mime: "text/plain; charset=utf-8")))
        #expect(LibraryDownloadType.images.includes(record("download", mime: "image/avif")))
        #expect(LibraryDownloadType.images.includes(record("PHOTO.HEIC")))
        #expect(LibraryDownloadType.archives.includes(record("bundle.tar.gz")))
        #expect(LibraryDownloadType.apps.includes(record("Browser.DMG")))
        #expect(!LibraryDownloadType.documents.includes(record("photo.png")))
        #expect(!LibraryDownloadType.archives.includes(record("Browser.dmg")))
    }

    @Test func dateUsesCalendarDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28)))
        #expect(LibraryDateFilter.lastSevenDays.includes(start, now: now, calendar: calendar))
        #expect(!LibraryDateFilter.lastSevenDays.includes(start.addingTimeInterval(-1), now: now, calendar: calendar))
        #expect(LibraryDateFilter.today.includes(calendar.startOfDay(for: now), now: now, calendar: calendar))
        #expect(!LibraryDateFilter.today.includes(now.addingTimeInterval(1), now: now, calendar: calendar))
    }

    @Test func dimensionsCombineAndArchiveKeepsSourceSpace() {
        var filter = LibraryDownloadFilter()
        filter.state = .complete
        filter.type = .documents
        filter.date = .today
        #expect(filter.includes(record(), now: now))
        #expect(!filter.includes(record("image.png"), now: now))
        var old = record()
        old.startedAt = now.addingTimeInterval(-40 * 86_400)
        #expect(!filter.includes(old, now: now))
        let space = UUID()
        let tab = Tab(kind: .today, title: "Archived", url: URL(string: "https://example.test")!)
        let record = ArchivedTabRecord(tab: tab, spaceID: space, archivedAt: now, reason: .manual)
        var archive = LibraryArchiveFilter()
        #expect(archive.includes(record, now: now))
        archive.spaceID = space
        archive.date = .today
        #expect(archive.includes(record, now: now))
        archive.spaceID = UUID()
        #expect(!archive.includes(record, now: now))
        archive = LibraryArchiveFilter()
        var deleted = record
        deleted.spaceID = nil
        #expect(archive.includes(deleted, now: now))
    }
}
