import Darwin
import Photos
import SwiftData
import UserNotifications
import XCTest
@testable import SnapSchedule

/// Discovery and image loading use bundle fixtures. Vision, Parser, SwiftData,
/// individual review/registration, mutations and Widget file IO are production code.
@MainActor
final class CoreFlowIntegrationTests: XCTestCase {
    func testOnePhotoBatchConnectsEveryScheduleToRemindersWidgetAndCalendarRetries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "batch.store")
        let context = ModelContext(try SnapScheduleModelContainer.make(url: url)); context.autosaveEnabled = false
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "batch-external-photo", sourceCandidateKey: "one",
            title: "Shared", date: CalendarDate(year: 2030, month: 10, day: 18),
            notifyDayBefore: true, notifySameDay: true, calendarExportRequested: true)
        candidate.dateEntries = [
            CandidateDateEntry(date: candidate.date, time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul"),
            CandidateDateEntry(date: CalendarDate(year: 2030, month: 10, day: 20), timeZoneIdentifier: "Asia/Tokyo")
        ]
        context.insert(candidate); try context.save()
        let widget = WidgetSnapshotStore(containerURL: { directory }, now: { self.now }, deviceTimeZone: { self.zone }, timelineReload: {})
        let result = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {
            try widget.write(schedules: context.fetch(FetchDescriptor<Schedule>()))
        }).register(candidateIDs: [candidate.id])
        XCTAssertEqual(result.scheduleIDs.count, 2)
        let reopened = ModelContext(try SnapScheduleModelContainer.make(url: url))
        let restored = try XCTUnwrap(try reopened.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(restored.id, candidate.id)
        XCTAssertEqual(restored.registeredScheduleIDs, result.scheduleIDs)
        XCTAssertEqual(restored.dateEntries.count, 2)
        guard case let .success(snapshot) = widget.read() else { return XCTFail("Missing batch Widget") }
        XCTAssertEqual(Set(snapshot.schedules.map(\.id)), Set(result.scheduleIDs))
        for id in result.scheduleIDs {
            XCTAssertEqual(WidgetScheduleLink.scheduleID(from: WidgetScheduleLink.url(for: id)), id)
        }
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        let failed = await NotificationScheduler(center: IntegrationNotificationCenter(failAdds: true), now: { self.now })
            .synchronize(schedules: schedules, access: .authorized)
        XCTAssertEqual(failed.state, .failed)
        let center = IntegrationNotificationCenter()
        let retried = await NotificationScheduler(center: center, now: { self.now }).synchronize(schedules: schedules, access: .authorized)
        XCTAssertEqual(retried.scheduledCount, 4)
        XCTAssertEqual(Set(center.requests.values.compactMap { NotificationPayload.scheduleID(from: $0.content.userInfo) }), Set(result.scheduleIDs))
        let writer = BatchCalendarWriter()
        let calendar = CalendarExportService(context: context, writer: writer)
        let failures = try await calendar.exportRequested(scheduleIDs: result.scheduleIDs)
        XCTAssertEqual(failures.failedCount, 2)
        XCTAssertEqual(candidate.reviewStatus, .registered)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 2)
        writer.fail = false
        for id in result.scheduleIDs { guard case .succeeded = await calendar.export(scheduleID: id) else { return XCTFail("Calendar retry failed") } }
        XCTAssertTrue(schedules.allSatisfy { $0.calendarExportStatus == .succeeded && $0.calendarEventIdentifier != nil })
        XCTAssertThrowsError(try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}).register(candidateIDs: [candidate.id]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 2)
    }
    private let zone = TimeZone(identifier: "Asia/Seoul")!
    private let now = Date(timeIntervalSince1970: 1_791_040_000)

    func testTwentyImagesIndividualReviewReopenAndMutationRemainConsistent() async throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.filter { $0.category == "none" }.count, 8)
        XCTAssertEqual(fixtures.filter { $0.category == "single" }.count, 8)
        XCTAssertEqual(fixtures.filter { $0.category == "multi" }.count, 2)
        XCTAssertEqual(fixtures.filter { $0.category == "edit" }.count, 2)
        let directory = try temporaryDirectory()
        let storeURL = directory.appendingPathComponent("synthetic.store")
        let container = try SnapScheduleModelContainer.make(url: storeURL)
        let context = container.mainContext
        context.autosaveEnabled = false
        let settings = try isolatedSettings()
        var loaded = 0, heartbeats = 0, stopProbe = false
        var maxProbeGap: TimeInterval = 0
        let probe = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !stopProbe {
                try? await Task.sleep(for: .milliseconds(10))
                let current = ProcessInfo.processInfo.systemUptime
                maxProbeGap = max(maxProbeGap, current - previous)
                previous = current; heartbeats += 1
            }
        }
        defer { stopProbe = true; probe.cancel() }
        let memoryBefore = footprintMiB()
        let started = ProcessInfo.processInfo.systemUptime
        let scan = coordinator(context: context, settings: settings, fixtures: fixtures, didLoad: { loaded += 1 })
        await scan.activate(access: .authorized)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        stopProbe = true; probe.cancel(); await probe.value
        print("[Task38 synthetic performance] images=20 elapsed=\(elapsed)s footprintBefore=\(memoryBefore)MiB footprintAfter=\(footprintMiB())MiB heartbeatCount=\(heartbeats) maxGap=\(maxProbeGap)s")
        XCTAssertGreaterThan(heartbeats, 0, "Vision must allow main actor work to continue")
        XCTAssertEqual(scan.status.state, .completed)
        XCTAssertEqual(scan.status.completedImageCount, 20)
        XCTAssertEqual(scan.status.failedImageCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScreenshotScan>()), 20)
        let candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(candidates.count, 12)
        for fixture in fixtures {
            let actual = candidates.filter { $0.sourceAssetIdentifier == fixture.id }
            XCTAssertEqual(actual.count, fixture.days.isEmpty ? 0 : 1, fixture.id)
            let recognized = actual.flatMap { $0.recognizedDateOptions.isEmpty ? $0.dateEntries : $0.recognizedDateOptions }
            XCTAssertEqual(recognized.compactMap { $0.date?.day }.sorted(), fixture.days.sorted(), fixture.id)
            XCTAssertEqual(recognized.compactMap { $0.time?.hour }.sorted(), fixture.hours.sorted(), fixture.id)
        }
        let allIDs = Set(candidates.map(\.id))
        let registration = ScheduleRegistrationService(context: context, now: { self.now }, timeZone: { self.zone }, widgetSnapshotRefresh: {})
        let chosen = ["single-01", "single-02", "multi-01"].flatMap { source in
            candidates.filter { $0.sourceAssetIdentifier == source }.sorted { $0.date!.day < $1.date!.day }
        }
        XCTAssertEqual(chosen.count, 3)
        var scheduleIDs: [UUID] = []
        for (index, candidate) in chosen.enumerated() {
            var draft = reviewed(candidate, title: "Synthetic reviewed \(index)")
            let service = ScheduleRegistrationService(context: context, now: { self.now.addingTimeInterval(Double(index)) }, timeZone: { self.zone }, widgetSnapshotRefresh: {})
            scheduleIDs += try draft.register(to: candidate, in: context, service: service).scheduleIDs
            XCTAssertThrowsError(try registration.register(candidateIDs: [candidate.id]))
        }
        for source in ["single-03", "multi-02"] {
            let candidate = try XCTUnwrap(candidates.first { $0.sourceAssetIdentifier == source })
            try CandidateDismissalService(context: context).dismiss(candidateIDs: [candidate.id])
        }
        let editCandidate = try XCTUnwrap(candidates.first { $0.sourceAssetIdentifier == "edit-01" })
        XCTAssertFalse(editCandidate.isRegistrationEligible)
        var savedReview = reviewed(editCandidate, title: "Synthetic saved review")
        try savedReview.save(to: editCandidate, in: context)

        // A fresh disk-backed container, not a reused in-memory context.
        let reopened = try SnapScheduleModelContainer.make(url: storeURL)
        let fresh = reopened.mainContext; fresh.autosaveEnabled = false
        let preserved = try fresh.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(Set(preserved.map(\.id)), allIDs)
        XCTAssertEqual(preserved.filter { $0.reviewStatus == .pending }.count, 7)
        XCTAssertEqual(preserved.filter { $0.reviewStatus == .registered }.count, 3)
        XCTAssertEqual(preserved.filter { $0.reviewStatus == .dismissed }.count, 2)
        XCTAssertEqual(preserved.first { $0.id == editCandidate.id }?.title, "Synthetic saved review")
        let restart = coordinator(context: fresh, settings: settings, fixtures: fixtures, didLoad: { loaded += 1 })
        await restart.activate(access: .authorized)
        XCTAssertEqual(loaded, 20, "Completed images must not be analyzed again")
        XCTAssertEqual(restart.status.targetImageCount, 0)
        XCTAssertEqual(restart.status.pendingCandidateCount, 7)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 4)

        let widget = WidgetSnapshotStore(containerURL: { directory }, now: { self.now }, deviceTimeZone: { self.zone }, timelineReload: {})
        let mutation = ScheduleMutationService(context: fresh, widgetSnapshotRefresh: {
            try widget.write(schedules: fresh.fetch(FetchDescriptor<Schedule>()))
        })
        let last = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Schedule>()).first { $0.id == scheduleIDs[3] })
        var edit = ScheduleEditDraft(schedule: last)
        edit.title = "Synthetic moved schedule"; edit.date = CalendarDate(year: 2027, month: 1, day: 20)
        edit.time = ClockTime(hour: 8, minute: 30)
        _ = try mutation.update(scheduleID: last.id, draft: edit)
        var schedules = try fresh.fetch(FetchDescriptor<Schedule>())
        let day = CalendarDate(year: 2027, month: 1, day: 20)
        let registeredOnDay = HomeCalendarPresentation.registeredSchedules(on: day, from: schedules).map(\.id)
        XCTAssertEqual(Array(registeredOnDay.prefix(2)), Array(scheduleIDs.prefix(2)))
        XCTAssertEqual(Set(registeredOnDay.suffix(2)), Set(scheduleIDs.suffix(2)), "Dates from one batch share a commit timestamp")
        let representative = try XCTUnwrap(HomeCalendarPresentation.originalsByDate(schedules).first)
        XCTAssertEqual(representative.scheduleID, scheduleIDs[0])
        XCTAssertEqual(representative.additionalCount, 3)
        XCTAssertEqual(schedules.filter { $0.sourceAssetIdentifier == "multi-01" }.count, 2)
        guard case let .success(snapshot) = widget.read() else { return XCTFail("Widget snapshot missing") }
        XCTAssertEqual(Set(snapshot.schedules.map(\.id)), Set(scheduleIDs))
        XCTAssertEqual(snapshot.schedules.first?.id, scheduleIDs[3], "Upcoming keeps chronological order, independent of registration order")
        XCTAssertEqual(snapshot.schedules.first?.title, "Synthetic moved schedule")

        let center = IntegrationNotificationCenter()
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let denied = await scheduler.synchronize(schedules: schedules, access: .denied)
        XCTAssertEqual(denied.state, .authorizationUnavailable)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 4)
        let allowed = await scheduler.synchronize(schedules: schedules, access: .authorized)
        XCTAssertEqual(allowed.scheduledCount, 8)
        XCTAssertEqual(Set(center.requests.values.compactMap { NotificationPayload.scheduleID(from: $0.content.userInfo) }), Set(scheduleIDs))
        let writer = IntegrationCalendarWriter()
        let calendar = CalendarExportService(context: fresh, writer: writer)
        let calendarDenied = await calendar.export(scheduleID: last.id)
        XCTAssertEqual(calendarDenied, .failed(.accessDenied))
        writer.access = .writeOnly
        let calendarFailed = await calendar.export(scheduleID: last.id)
        XCTAssertEqual(calendarFailed, .failed(.eventSaveFailed))
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 4)
        let failedScheduler = NotificationScheduler(center: IntegrationNotificationCenter(failAdds: true), now: { self.now })
        let failedNotification = await failedScheduler.synchronize(schedules: schedules, access: .authorized)
        XCTAssertEqual(failedNotification.state, .failed)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 4)

        let preview = ScreenshotPreviewModel(sourceScreenshotIdentifier: last.sourceAssetIdentifier) { _, _ in throw ScreenshotImageLoadError.inaccessible }
        preview.load()
        for _ in 0..<100 where preview.status == .loadingLocal { await Task.yield() }
        XCTAssertEqual(preview.status, .inaccessible)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 4)
        await restart.activate(access: .denied)
        XCTAssertEqual(restart.status.state, .accessUnavailable)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 4)
        _ = try mutation.delete(scheduleID: scheduleIDs[0])
        schedules = try fresh.fetch(FetchDescriptor<Schedule>())
        let deletedSync = await scheduler.synchronize(schedules: schedules, access: .authorized)
        XCTAssertEqual(deletedSync.scheduledCount, 6)
        XCTAssertFalse(center.requests.values.contains { NotificationPayload.scheduleID(from: $0.content.userInfo) == scheduleIDs[0] })
        guard case let .success(deletedSnapshot) = widget.read() else { return XCTFail("Widget snapshot missing after deletion") }
        XCTAssertEqual(deletedSnapshot.schedules.count, 3)
        XCTAssertFalse(deletedSnapshot.schedules.contains { $0.id == scheduleIDs[0] })
        let afterDeletion = try XCTUnwrap(HomeCalendarPresentation.originalsByDate(schedules).first)
        XCTAssertEqual(afterDeletion.scheduleID, scheduleIDs[1]); XCTAssertEqual(afterDeletion.additionalCount, 2)
        await restart.activate(access: .limited)
        XCTAssertEqual(loaded, 20)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 3)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ScheduleCandidate>()), 12)
        for id in scheduleIDs.dropFirst() {
            let link = WidgetScheduleLink.url(for: id)
            XCTAssertEqual(WidgetScheduleLink.scheduleID(from: link), id)
            let navigation = NotificationNavigationStore()
            navigation.receive(userInfo: [NotificationPayload.scheduleIDKey: id.uuidString])
            XCTAssertEqual(navigation.destination?.scheduleID, id)
        }
    }

    func testRegistrationSaveBoundaryReopenKeepsReviewAndExactlyOneSchedule() async throws {
        let directory = try temporaryDirectory(), settings = try isolatedSettings()
        let url = directory.appendingPathComponent("synthetic-boundary.store")
        let container = try SnapScheduleModelContainer.make(url: url)
        let context = container.mainContext; context.autosaveEnabled = false
        let fixture = try XCTUnwrap(loadFixtures().first { $0.id == "edit-01" })
        await coordinator(context: context, settings: settings, fixtures: [fixture]).activate(access: .authorized)
        let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        var draft = reviewed(candidate, title: "Synthetic durable review")
        let failing = ScheduleRegistrationService(context: context, save: { _ in throw IntegrationError.save }, widgetSnapshotRefresh: {})
        XCTAssertThrowsError(try draft.register(to: candidate, in: context, service: failing))
        let reopened = try SnapScheduleModelContainer.make(url: url)
        let fresh = reopened.mainContext; fresh.autosaveEnabled = false
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 0)
        let restored = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(restored.reviewStatus, .pending); XCTAssertNil(restored.registeredScheduleID)
        XCTAssertEqual(restored.title, "Synthetic durable review")
        var retry = CandidateDetailDraft(candidate: restored)
        let result = try retry.register(to: restored, in: fresh, service: ScheduleRegistrationService(context: fresh, widgetSnapshotRefresh: {}))
        let committed = try SnapScheduleModelContainer.make(url: url)
        let committedContext = committed.mainContext
        let committedCandidate = try XCTUnwrap(try committedContext.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(committedCandidate.registeredScheduleID, result.scheduleIDs.first)
        XCTAssertThrowsError(try ScheduleRegistrationService(context: committedContext, widgetSnapshotRefresh: {}).register(candidateIDs: [restored.id]))
        XCTAssertEqual(try committedContext.fetchCount(FetchDescriptor<Schedule>()), 1)
        let schedule = try XCTUnwrap(try committedContext.fetch(FetchDescriptor<Schedule>()).first)
        schedule.calendarExportStatus = .exporting; try committedContext.save()
        let recovered = try SnapScheduleModelContainer.make(url: url)
        let export = CalendarExportService(context: recovered.mainContext, writer: IntegrationCalendarWriter())
        XCTAssertEqual(try export.recoverInterruptedExports(), 1)
        let unknown = await export.export(scheduleID: schedule.id)
        XCTAssertEqual(unknown, .confirmationRequired)
        XCTAssertEqual(try recovered.mainContext.fetchCount(FetchDescriptor<Schedule>()), 1)
    }

    func testHundredLargeImagesRealVisionKeepsMainActorResponsive() async throws {
        let fixtures = (0..<100).map { IntegrationFixture(id: "large-synthetic-\($0)", category: "single", days: [20], hours: [14]) }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext; context.autosaveEnabled = false
        let settings = try isolatedSettings()
        var stopped = false, ticks = 0
        let initialMemory = footprintMiB()
        var peakMemory = initialMemory, maxGap: TimeInterval = 0
        let probe = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !stopped && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let current = ProcessInfo.processInfo.systemUptime
                maxGap = max(maxGap, current - previous); previous = current
                peakMemory = max(peakMemory, footprintMiB()); ticks += 1
            }
        }
        defer { stopped = true; probe.cancel() }
        var imageLoads = 0
        let scanner = coordinator(context: context, settings: settings, fixtures: fixtures, resourceID: { _ in "single-01" }, didLoad: { imageLoads += 1 })
        let start = ProcessInfo.processInfo.systemUptime
        await scanner.activate(access: .authorized)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        stopped = true; probe.cancel(); await probe.value
        XCTAssertEqual(scanner.status.state, .completed)
        XCTAssertEqual(scanner.status.completedImageCount, 100)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScreenshotScan>()), 100)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 100)
        XCTAssertGreaterThan(ticks, 0)
        await scanner.activate(access: .authorized)
        XCTAssertEqual(imageLoads, 100)
        XCTAssertEqual(scanner.status.targetImageCount, 0)
        print("[Task38 large real Vision] images=100 size=1200x1800 elapsed=\(elapsed)s memoryBefore=\(initialMemory)MiB sampledPeak=\(peakMemory)MiB memoryAfter=\(footprintMiB())MiB mainActorMaxGap=\(maxGap)s")
    }

    /// Explicit physical-device runs only. A fresh run UUID isolates every store
    /// from the app's default store and from earlier validation runs.
    func testDeviceProcessTerminationBoundary() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical process termination only")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let run = environment["TASK38_BOUNDARY_RUN_ID"], UUID(uuidString: run) != nil,
              let mode = environment["TASK38_BOUNDARY_MODE"],
              ["analysis", "registration-before-save", "registration-after-save", "recover-analysis", "recover-registration-before-save", "recover-registration-after-save"].contains(mode) else {
            throw XCTSkip("Requires an explicit isolated Task38 boundary run")
        }
        let recovering = mode.hasPrefix("recover-")
        let boundary = recovering ? String(mode.dropFirst("recover-".count)) : mode
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Task38-boundary-\(run)-\(boundary)")
        let storeURL = directory.appendingPathComponent("synthetic.store")
        let markerURL = directory.appendingPathComponent("termination-marker.json")
        if recovering {
            XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
            XCTAssertEqual(marker?["boundary"] as? String, boundary)
            XCTAssertEqual(marker?["run"] as? String, run)
            XCTAssertNotEqual(marker?["pid"] as? Int, Int(getpid()), "Recovery must run in a new process")
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Never reuse a staged boundary store")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let container = try SnapScheduleModelContainer.make(url: storeURL)
        let context = container.mainContext; context.autosaveEnabled = false
        let settings = try isolatedSettings()
        let fixture = try XCTUnwrap(loadFixtures().first { $0.id == "single-01" })
        func terminate() throws -> Never {
            let marker: [String: Any] = ["run": run, "boundary": boundary, "pid": Int(getpid())]
            try JSONSerialization.data(withJSONObject: marker).write(to: markerURL, options: .atomic)
            print("[Task38 process termination ready] run=\(run) boundary=\(boundary) pid=\(getpid()) signal=SIGKILL")
            fflush(stdout)
            kill(getpid(), SIGKILL)
            throw IntegrationError.save // Reached only if OS termination did not occur.
        }
        if !recovering {
            let recognition: ScanCoordinator.RecognizeText = { input in
                let text = try await TextRecognitionService().recognize(input)
                if boundary == "analysis" { try terminate() }
                return text
            }
            await coordinator(context: context, settings: settings, fixtures: [fixture], recognizeText: recognition).activate(access: .authorized)
            let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
            var draft = reviewed(candidate, title: "Task38 synthetic durable boundary")
            try draft.save(to: candidate, in: context)
            let registration = ScheduleRegistrationService(context: context, save: { pending in
                if boundary == "registration-after-save" { try pending.save() }
                try terminate()
            }, widgetSnapshotRefresh: {})
            _ = try draft.register(to: candidate, in: context, service: registration)
            XCTFail("Staged process must terminate at the requested boundary")
            return
        }
        let before = try context.fetch(FetchDescriptor<ScheduleCandidate>())
        let committed = boundary == "registration-after-save"
        XCTAssertEqual(before.count, boundary == "analysis" ? 0 : 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), committed ? 1 : 0)
        if let candidate = before.first {
            XCTAssertEqual(candidate.title, "Task38 synthetic durable boundary")
            XCTAssertEqual(candidate.reviewStatus, committed ? .registered : .pending)
            XCTAssertEqual(candidate.registeredScheduleID != nil, committed)
        }
        if boundary == "analysis" {
            let interrupted = try XCTUnwrap(try context.fetch(FetchDescriptor<ScreenshotScan>()).first)
            XCTAssertEqual(interrupted.status, .analyzing)
        }
        var loads = 0
        let scanner = coordinator(context: context, settings: settings, fixtures: [fixture], didLoad: { loads += 1 })
        await scanner.activate(access: .authorized)
        XCTAssertEqual(loads, boundary == "analysis" ? 1 : 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScreenshotScan>()), 1)
        let scan = try XCTUnwrap(try context.fetch(FetchDescriptor<ScreenshotScan>()).first)
        XCTAssertEqual(scan.status, .completed)
        let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        if !committed {
            var draft = reviewed(candidate, title: "Task38 synthetic recovered boundary")
            _ = try draft.register(to: candidate, in: context, service: ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}))
        }
        XCTAssertThrowsError(try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}).register(candidateIDs: [candidate.id]))
        let reopened = try SnapScheduleModelContainer.make(url: storeURL)
        let fresh = reopened.mainContext
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ScheduleCandidate>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 1)
        let recoveredCandidate = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        let schedule = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(recoveredCandidate.reviewStatus, .registered)
        XCTAssertEqual(recoveredCandidate.registeredScheduleID, schedule.id)
        XCTAssertEqual(schedule.sourceCandidateID, recoveredCandidate.id)
        print("[Task38 process recovery] run=\(run) boundary=\(boundary) pid=\(getpid()) candidates=1 schedules=1 imageLoads=\(loads) duplicateRejected=true")
        #endif
    }

    /// Real SDK request, one approved source, isolated persistence. No normal
    /// app-store mutation, new permission, synthetic image, or Calendar write.
    func testDeviceRealPhotoKitRequestTerminationAndRecovery() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Explicit test-phone real PhotoKit request only")
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["TASK38_REAL_PHOTOKIT_DEVICE"] == "00000000-0000000000000000",
              let run = env["TASK38_REAL_PHOTOKIT_RUN"], UUID(uuidString: run) != nil,
              let mode = env["TASK38_REAL_PHOTOKIT_MODE"], ["request", "recover"].contains(mode) else {
            throw XCTSkip("Requires explicit one-source real PhotoKit request boundary invocation")
        }
        XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .readWrite), .authorized)
        // Read only the already approved pending test source, rather than
        // guessing a photo by album position or enumerating private content.
        let appContainer = try SnapScheduleModelContainer.makeDefault()
        let sourceTitle = "Task38 잔여 검증"
        var descriptor = FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.title.contains(sourceTitle) })
        descriptor.fetchLimit = 3
        let approved = try appContainer.mainContext.fetch(descriptor)
        guard approved.count == 1, approved[0].date == CalendarDate(year: 2026, month: 10, day: 6),
              approved[0].time == ClockTime(hour: 16, minute: 0) else {
            throw XCTSkip("Known October6 test candidate unavailable; no substitute source")
        }
        let sourceID = approved[0].sourceAssetIdentifier
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [sourceID], options: nil).firstObject)
        XCTAssertTrue(asset.mediaSubtypes.contains(.photoScreenshot))
        let metadata = ScreenshotAssetMetadata(assetIdentifier: sourceID, creationDate: asset.creationDate,
                                              pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Task38-real-PhotoKit-" + run)
        let markerURL = directory.appendingPathComponent("request-marker.json")
        let recovering = mode == "recover"
        if recovering {
            let marker = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
            XCTAssertEqual(marker["run"] as? String, run)
            XCTAssertEqual(marker["sourceID"] as? String, sourceID)
            XCTAssertEqual(marker["sdkRequestIssued"] as? Bool, true)
            XCTAssertNotEqual(marker["pid"] as? Int, Int(getpid()))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let container = try SnapScheduleModelContainer.make(url: directory.appendingPathComponent("isolated-real.store"))
        let context = container.mainContext
        context.autosaveEnabled = false
        let defaultsName = "Task38-real-PhotoKit-" + run
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let settings = AppSettings(userDefaults: defaults)
        settings.screenshotAnalysisBaselineDate = asset.creationDate!.addingTimeInterval(-1)
        let manager = PHImageManager()
        let state = Task38RealPhotoKitBoundaryState()
        let loader: ScreenshotImageLoader
        if recovering {
            let interrupted = try XCTUnwrap(try context.fetch(FetchDescriptor<ScreenshotScan>()).first)
            XCTAssertEqual(interrupted.assetIdentifier, sourceID)
            XCTAssertEqual(interrupted.status, .analyzing)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 0)
            loader = ScreenshotImageLoader(imageManager: manager)
        } else {
            loader = ScreenshotImageLoader(request: { identifier, receive in
                guard let requested = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                    receive(.failed(.inaccessible)); return PHInvalidImageRequestID
                }
                let options = PHImageRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                let requestID = manager.requestImageDataAndOrientation(for: requested, options: options) { data, _, orientation, info in
                    state.markCallback()
                    receive(ScreenshotPhotoKitEventAdapter.result(data: data, orientation: orientation, info: info, source: .local))
                }
                guard requestID != PHInvalidImageRequestID else { return requestID }
                do {
                    let marker: [String: Any] = ["run": run, "sourceID": identifier, "pid": Int(getpid()),
                                               "sdkRequestIssued": true, "requestID": requestID]
                    try JSONSerialization.data(withJSONObject: marker).write(to: markerURL, options: .atomic)
                    // Do not hold the callback lock while writing or waiting:
                    // a completed local request must never be relabeled active.
                    if state.callbackHasArrived {
                        try FileManager.default.removeItem(at: markerURL)
                        return requestID
                    }
                    print("[Task38 real PhotoKit boundary] actualSDKRequestIssued=true callbackArrived=false requestID=\(requestID) pid=\(getpid()) signal=SIGKILL")
                    fflush(stdout)
                    kill(getpid(), SIGKILL)
                } catch {
                    print("[Task38 real PhotoKit boundary] marker failed; no termination")
                }
                return requestID
            }, cancelRequest: { manager.cancelImageRequest($0) })
        }
        var imageLoads = 0
        let scanner = ScanCoordinator(context: context, settings: settings,
            discover: { _ in .authorized([metadata]) },
            loadImage: { identifier, report in
                imageLoads += 1
                return try await loader.load(assetIdentifier: identifier, onPhase: report)
            }, recognizeText: { try await TextRecognitionService().recognize($0) },
            timeZone: { TimeZone(identifier: "US/Pacific")! })
        await scanner.activate(access: .authorized)
        if !recovering {
            throw XCTSkip("Real local PhotoKit callback arrived before signal boundary; no delayed/synthetic replacement")
        }
        XCTAssertEqual(scanner.status.state, .completed)
        XCTAssertEqual(imageLoads, 1)
        let candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.sourceAssetIdentifier == sourceID })
        XCTAssertTrue(candidates.contains { $0.title.contains(sourceTitle) && $0.date == CalendarDate(year: 2026, month: 10, day: 6) && $0.time == ClockTime(hour: 16, minute: 0) })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        await scanner.activate(access: .authorized)
        XCTAssertEqual(imageLoads, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 2)
        XCTAssertEqual(try appContainer.mainContext.fetch(descriptor).count, 1, "Normal app's approved candidate was only read")
        print("[Task38 real PhotoKit recovery] newPID=\(getpid()) realSource=1 candidates=2 requestLoads=1 repeatLoads=0 normalAppStoreUnmodified=true")
        defaults.removePersistentDomain(forName: defaultsName)
        #endif
    }

    private func coordinator(context: ModelContext, settings: AppSettings, fixtures: [IntegrationFixture], resourceID: @escaping (String) -> String = { $0 }, didLoad: @escaping () -> Void = {}, recognizeText: ScanCoordinator.RecognizeText? = nil) -> ScanCoordinator {
        let assets = fixtures.enumerated().map { index, fixture in ScreenshotAssetMetadata(assetIdentifier: fixture.id, creationDate: now.addingTimeInterval(Double(index + 1)), pixelWidth: 1200, pixelHeight: 1800) }
        return ScanCoordinator(context: context, settings: settings,
            discover: { access in access.canReadAccessiblePhotos ? (access == .limited ? .limited(assets) : .authorized(assets)) : .unavailable(access) },
            loadImage: { identifier, _ in
                didLoad()
                let url = try XCTUnwrap(Bundle(for: CoreFlowIntegrationTests.self).url(forResource: resourceID(identifier), withExtension: "png", subdirectory: "Fixtures"))
                return ScreenshotImageInput(data: try Data(contentsOf: url), orientation: .up)
            }, recognizeText: recognizeText ?? { try await TextRecognitionService().recognize($0) }, analysisDate: { self.now }, timeZone: { self.zone })
    }

    private func reviewed(_ candidate: ScheduleCandidate, title: String) -> CandidateDetailDraft {
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.title = title
        if !candidate.recognizedDateOptions.isEmpty {
            draft.dateEntries = candidate.recognizedDateOptions.map(CandidateDateDraft.init)
        }
        for index in draft.dateEntries.indices {
            draft.dateEntries[index].confirmedReviewReasons = Set(draft.dateEntries[index].originalReviewReasons)
        }
        draft.notifyDayBefore = true; draft.notifySameDay = true
        return draft
    }
    private func loadFixtures() throws -> [IntegrationFixture] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([IntegrationFixture].self, from: Data(contentsOf: url))
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Task38-synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Keep disk stores in test-host tmp until process exit: SwiftData may retain open SQLite handles.
        return url
    }
    private func isolatedSettings() throws -> AppSettings {
        let name = "Task38-synthetic-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(userDefaults: defaults)
        settings.screenshotAnalysisBaselineDate = now.addingTimeInterval(-1)
        return settings
    }
    private func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

private struct IntegrationFixture: Decodable { let id: String; let category: String; let days: [Int]; let hours: [Int] }
private enum IntegrationError: Error { case save }
@MainActor private final class IntegrationNotificationCenter: NotificationCenterScheduling {
    var requests: [String: UNNotificationRequest] = [:]
    let failAdds: Bool
    init(failAdds: Bool = false) { self.failAdds = failAdds }
    func pendingRequests() async -> [UNNotificationRequest] { Array(requests.values) }
    func add(_ request: UNNotificationRequest) async throws {
        if failAdds { throw IntegrationError.save }
        requests[request.identifier] = request
    }
    func removePendingRequests(withIdentifiers ids: [String]) { ids.forEach { requests.removeValue(forKey: $0) } }
}
@MainActor private final class IntegrationCalendarWriter: CalendarEventWriting {
    var access = CalendarAuthorizationAccess.denied
    func requestWriteOnlyAccess() async throws -> CalendarAuthorizationAccess { access }
    func save(_ event: CalendarEventDraft) throws -> String? { throw IntegrationError.save }
}

/// Read-only real service evidence; does not request permission, load personal
/// images, export events, schedule notifications, or copy any user store.
@MainActor final class DeviceServiceReadOnlyTests: XCTestCase {
    func testReadOnlyReconnectedApprovedReminderBoundary() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical approved test schedule observation only")
        #else
        guard ProcessInfo.processInfo.environment["TASK38_READ_APPROVED_SOURCE"] == "00000000-0000000000000000" else {
            throw XCTSkip("Explicit approved test device opt-in required")
        }
        let container = try SnapScheduleModelContainer.makeDefault()
        let title = "Task38 테스트"
        var descriptor = FetchDescriptor<Schedule>(predicate: #Predicate { $0.title == title })
        descriptor.fetchLimit = 2
        let saved = try container.mainContext.fetch(descriptor)
        XCTAssertEqual(saved.count, 1)
        let schedule = try XCTUnwrap(saved.first)
        XCTAssertEqual(schedule.date, CalendarDate(year: 2026, month: 10, day: 5))
        XCTAssertEqual(schedule.time, ClockTime(hour: 16, minute: 0))
        XCTAssertEqual(schedule.timeZoneIdentifier, "US/Pacific")
        XCTAssertTrue(schedule.notifyDayBefore && schedule.notifySameDay)
        XCTAssertEqual(schedule.calendarExportStatus, .succeeded)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter {
            NotificationPayload.scheduleID(from: $0.content.userInfo) == schedule.id
        }
        let delivered = await center.deliveredNotifications().filter {
            NotificationPayload.scheduleID(from: $0.request.content.userInfo) == schedule.id
        }
        func report(_ request: UNNotificationRequest, state: String, deliveredDate: Date? = nil) {
            let kind = request.content.userInfo[NotificationPayload.reminderKindKey] as? String ?? "missing"
            let trigger = (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents
            print("[Task38 approved reminder read-only] state=\(state) kind=\(kind) calendarTrigger=\(String(describing: trigger)) deliveredDate=\(String(describing: deliveredDate))")
        }
        for request in pending { report(request, state: "pending") }
        for notification in delivered { report(notification.request, state: "delivered", deliveredDate: notification.date) }
        print("[Task38 approved reminder read-only] deviceTimeZone=\(TimeZone.current.identifier) observedAt=\(Date()) pendingOwned=\(pending.count) deliveredOwned=\(delivered.count) schedulePreserved=true noMutation=true")
        #endif
    }

    func testAuthorizedUIRegistrationStateReadOnly() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical authorized test phone only")
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["TASK38_AUTHORIZED_UI_READ"] == "00000000-0000000000000000" else {
            throw XCTSkip("Explicit scoped authorized-fixture read required")
        }
        let container = try SnapScheduleModelContainer.makeDefault()
        let context = container.mainContext
        let originalSource = "ACEE8754-B134-4156-B95F-9F79FE4F93FA/L0/001"
        let originals = try context.fetch(FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.sourceAssetIdentifier == originalSource }))
        XCTAssertEqual(Set(originals.map { $0.id.uuidString }), Set(["C71607C9-1864-4E0D-BB09-7C3A768BB6F6", "C8713AFB-8846-4626-ADC1-8043B6E0BDDA"]))
        XCTAssertTrue(originals.allSatisfy { $0.reviewStatus == .pending && $0.registeredScheduleID == nil })
        let originalTitle = "Task38 테스트"
        let originalSchedules = try context.fetch(FetchDescriptor<Schedule>(predicate: #Predicate { $0.title == originalTitle }))
        XCTAssertEqual(originalSchedules.count, 1)
        let original = try XCTUnwrap(originalSchedules.first)
        XCTAssertEqual(original.id.uuidString, "244593CC-077B-45EA-804C-33FD9BA26AA4")
        XCTAssertEqual(original.date, CalendarDate(year: 2026, month: 10, day: 5))
        XCTAssertEqual(original.time, ClockTime(hour: 16, minute: 0))
        XCTAssertEqual(original.timeZoneIdentifier, "US/Pacific")
        XCTAssertTrue(original.notifyDayBefore && original.notifySameDay)
        XCTAssertEqual(original.calendarExportStatus, .succeeded)
        XCTAssertEqual(TimeZone.current.identifier, "US/Pacific")
        var rows: [[String: Any]] = []
        for letter in (env["TASK38_INCLUDE_D"] == "1" ? ["A", "B", "C", "D"] : ["A", "B", "C"]) {
            let marker = "Task38 USB " + letter + "1005"
            let candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.title.contains(marker) }))
            let schedules = try context.fetch(FetchDescriptor<Schedule>(predicate: #Predicate { $0.title.contains(marker) }))
            let expected = Int(env["TASK38_EXPECT_" + letter] ?? "-1")!
            XCTAssertGreaterThanOrEqual(expected, 0)
            XCTAssertEqual(schedules.count, expected)
            XCTAssertEqual(candidates.count, 1)
            let candidate = try XCTUnwrap(candidates.first)
            XCTAssertEqual(candidate.date, CalendarDate(year: 2026, month: 10, day: 7))
            XCTAssertEqual(candidate.time, ClockTime(hour: 16, minute: 0))
            XCTAssertEqual(candidate.timeZoneIdentifier, "US/Pacific")
            let photo = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.sourceAssetIdentifier], options: nil).firstObject
            XCTAssertNotNil(photo)
            if expected == 0 {
                XCTAssertEqual(candidate.reviewStatus, .pending)
                XCTAssertNil(candidate.registeredScheduleID)
            } else {
                XCTAssertEqual(candidate.reviewStatus, .registered)
                let schedule = try XCTUnwrap(schedules.first)
                XCTAssertEqual(candidate.registeredScheduleID, schedule.id)
                XCTAssertEqual(schedule.date, candidate.date)
                XCTAssertEqual(schedule.time, candidate.time)
                XCTAssertEqual(schedule.timeZoneIdentifier, "US/Pacific")
                XCTAssertEqual(schedule.calendarExportStatus, letter == "B" ? .succeeded : .notRequested)
            }
            rows.append(["marker": marker, "sourceID": candidate.sourceAssetIdentifier,
                         "candidateID": candidate.id.uuidString, "reviewStatus": String(describing: candidate.reviewStatus),
                         "scheduleIDs": schedules.map { $0.id.uuidString },
                         "calendarStatuses": schedules.map { String(describing: $0.calendarExportStatus) },
                         "photoPresent": photo != nil])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        print("[Task38 authorized exact read] " + String(decoding: data, as: UTF8.self))
        print("[Task38 authorized exact read] originalCandidates2AndSchedulePreserved=true timeZone=\(TimeZone.current.identifier) CalendarAccess=\(CalendarAuthorizationAccess.current) epoch=\(Date().timeIntervalSince1970) noMutation=true")
        #endif
    }

    func testAuthorizedRepeatedNativeInputsReadOnly() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical authorized phone only")
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["TASK38_AUTHORIZED_UI_READ"] == "00000000-0000000000000000" else {
            throw XCTSkip("Explicit scoped repeated-input read required")
        }
        let container = try SnapScheduleModelContainer.makeDefault()
        let context = container.mainContext
        let prefix = "Task38 USB R1005"
        var query = FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.title.contains(prefix) })
        query.fetchLimit = 13
        let candidates = try context.fetch(query)
        let expectedLetters = try XCTUnwrap(env["TASK38_REPEATED_EXPECTED_LETTERS"])
        XCTAssertTrue(["ABCDEFGHI", "ABCDEFGHIJKL"].contains(expectedLetters))
        var expected = Set(Array(expectedLetters).map { prefix + " " + String($0) + " · 장소: 테스트룸" })
        // Observed real OCR I→1 from the exact owned screenshot, not a fabricated title.
        expected.remove(prefix + " I · 장소: 테스트룸")
        expected.insert(prefix + "1 · 장소: 테스트룸")
        XCTAssertEqual(candidates.count, expected.count)
        XCTAssertEqual(Set(candidates.map(\.title)), expected)
        XCTAssertEqual(Set(candidates.map(\.sourceAssetIdentifier)).count, expected.count)
        var rows: [[String: Any]] = []
        for candidate in candidates {
            XCTAssertEqual(candidate.reviewStatus, .pending)
            XCTAssertNil(candidate.registeredScheduleID)
            XCTAssertEqual(candidate.date, CalendarDate(year: 2026, month: 10, day: 8))
            XCTAssertEqual(candidate.time, ClockTime(hour: 16, minute: 0))
            XCTAssertEqual(candidate.timeZoneIdentifier, "US/Pacific")
            let source = candidate.sourceAssetIdentifier
            let scans = try context.fetch(FetchDescriptor<ScreenshotScan>(predicate: #Predicate { $0.assetIdentifier == source }))
            XCTAssertEqual(scans.count, 1)
            let scan = try XCTUnwrap(scans.first)
            XCTAssertEqual(scan.status, .completed)
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [source], options: nil).firstObject)
            XCTAssertTrue(asset.mediaSubtypes.contains(.photoScreenshot))
            rows.append(["title": candidate.title, "candidateID": candidate.id.uuidString,
                         "sourceID": source, "scanStatus": String(describing: scan.status),
                         "analyzedAt": scan.analyzedAt?.timeIntervalSince1970 ?? 0,
                         "capturedAt": asset.creationDate?.timeIntervalSince1970 ?? 0])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        print("[Task38 repeated native exact read] " + String(decoding: data, as: UTF8.self))
        #endif
    }

    func testRealPhotoKitAndNotificationAuthorizationReadOnly() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone service observation only")
        #else
        let photos = PhotoAuthorizationService()
        let discovery = await ScreenshotDiscoveryService().discover(access: photos.access)
        switch discovery {
        case let .authorized(assets), let .limited(assets):
            XCTAssertTrue(photos.access.canReadAccessiblePhotos)
            XCTAssertEqual(Set(assets.map(\.assetIdentifier)).count, assets.count)
            print("[Task38 device read-only] PhotoKit access=\(photos.access) screenshotMetadataCount=\(assets.count)")
        case let .unavailable(access):
            XCTAssertFalse(access.canReadAccessiblePhotos)
            print("[Task38 device read-only] PhotoKit access=\(access) no image access")
        }
        if ProcessInfo.processInfo.environment["TASK38_READ_APPROVED_SOURCE"] == "00000000-0000000000000000" {
            let container = try SnapScheduleModelContainer.makeDefault()
            let title = "Task38 잔여 검증"
            var descriptor = FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.title.contains(title) })
            descriptor.fetchLimit = 3
            let approved = try container.mainContext.fetch(descriptor)
            XCTAssertEqual(approved.count, 1)
            let candidate = try XCTUnwrap(approved.first)
            XCTAssertEqual(candidate.date, CalendarDate(year: 2026, month: 10, day: 6))
            XCTAssertEqual(candidate.time, ClockTime(hour: 16, minute: 0))
            let sourceID = candidate.sourceAssetIdentifier
            var sourceCandidates = FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.sourceAssetIdentifier == sourceID })
            sourceCandidates.fetchLimit = 3
            XCTAssertEqual(try container.mainContext.fetch(sourceCandidates).count, 2)
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceID], options: nil).firstObject
            var inDiscovery = false
            switch discovery {
            case let .authorized(assets), let .limited(assets): inDiscovery = assets.contains { $0.assetIdentifier == sourceID }
            default: break
            }
            print("[Task38 approved source read-only] sdkAssetPresent=\(asset != nil) inScreenshotDiscovery=\(inDiscovery) sourceCandidates=2 noStoreOrPhotoMutation=true")
            if let asset {
                XCTAssertTrue(asset.mediaSubtypes.contains(.photoScreenshot))
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "US/Pacific")!
                let date = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(asset.creationDate))
                XCTAssertEqual(date.year, 2026); XCTAssertEqual(date.month, 10); XCTAssertEqual(date.day, 4)
                XCTAssertEqual(date.hour, 3); XCTAssertEqual(date.minute, 15)
                let input = try await ScreenshotImageLoader().load(assetIdentifier: sourceID)
                let recognized = try await TextRecognitionService().recognize(input)
                XCTAssertTrue(recognized.contains { $0.text.contains("Task38") })
                print("[Task38 approved source read-only] realSDKImageLoaded=true approvedTask38TextRecognized=true")
            }
            let scheduleTitle = "Task38 테스트"
            var schedules = FetchDescriptor<Schedule>(predicate: #Predicate { $0.title == scheduleTitle })
            schedules.fetchLimit = 2
            let saved = try container.mainContext.fetch(schedules)
            XCTAssertEqual(saved.count, 1)
            let schedule = try XCTUnwrap(saved.first)
            XCTAssertEqual(schedule.date, CalendarDate(year: 2026, month: 10, day: 5))
            XCTAssertEqual(schedule.time, ClockTime(hour: 16, minute: 0))
            XCTAssertEqual(schedule.timeZoneIdentifier, "US/Pacific")
            XCTAssertTrue(schedule.notifyDayBefore && schedule.notifySameDay)
            XCTAssertEqual(schedule.calendarExportStatus, .succeeded)
            print("[Task38 approved fixture read-only] schedule1 originalOctober5 16:00 US/Pacific reminders2 CalendarExported=true")
        }
        let notifications = NotificationAuthorizationService()
        await notifications.refresh()
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        print("[Task38 device read-only] notificationAccess=\(notifications.access) pendingCount=\(pending.count) CalendarAccess=\(CalendarAuthorizationAccess.current)")
        #endif
    }
}

/// Explicit cleanup of this session's disposable records, never a validation substitute.
@MainActor final class DeviceAuthorizedFixtureCleanupTests: XCTestCase {
    private struct OwnedFixture: Decodable {
        let title: String
        let candidateID: UUID
        let sourceID: String
        let scheduleIDs: [UUID]
    }

    func testCleanupOnlyManifestOwnedFixtures() async throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Designated physical phone cleanup only")
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["TASK38_AUTHORIZED_UI_READ"] == "00000000-0000000000000000",
              env["TASK38_EXECUTE_OWNED_CLEANUP"] == "1" else {
            throw XCTSkip("Explicit disposable fixture manifest and cleanup opt-in required")
        }
        let manifest = try XCTUnwrap(env["TASK38_CLEANUP_MANIFEST"]?.data(using: .utf8))
        let owned = try JSONDecoder().decode([OwnedFixture].self, from: manifest)
        XCTAssertFalse(owned.isEmpty)
        XCTAssertLessThanOrEqual(owned.count, 16)
        XCTAssertEqual(Set(owned.map(\.candidateID)).count, owned.count)
        var allowed = Set(["A", "B", "C", "D"].map { "Task38 USB " + $0 + "1005 · 장소: 테스트룸" })
        allowed.formUnion(Array("ABCDEFGHIJKL").map { "Task38 USB R1005 " + String($0) + " · 장소: 테스트룸" })
        allowed.insert("Task38 USB R10051 · 장소: 테스트룸")
        let container = try SnapScheduleModelContainer.makeDefault()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let originalSource = "ACEE8754-B134-4156-B95F-9F79FE4F93FA/L0/001"
        let originalCandidates = try context.fetch(FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.sourceAssetIdentifier == originalSource }))
        XCTAssertEqual(Set(originalCandidates.map { $0.id.uuidString }), Set(["C71607C9-1864-4E0D-BB09-7C3A768BB6F6", "C8713AFB-8846-4626-ADC1-8043B6E0BDDA"]))
        XCTAssertTrue(originalCandidates.allSatisfy { $0.reviewStatus == .pending && $0.registeredScheduleID == nil })
        var deleteCandidates: [ScheduleCandidate] = []
        var deleteSchedules: [Schedule] = []
        // Validate every identity before the first deletion. No wildcard mutations.
        for entry in owned {
            XCTAssertTrue(allowed.contains(entry.title))
            XCTAssertNotEqual(entry.sourceID, originalSource)
            let id = entry.candidateID
            let matches = try context.fetch(FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.id == id }))
            XCTAssertEqual(matches.count, 1)
            let candidate = try XCTUnwrap(matches.first)
            XCTAssertEqual(candidate.title, entry.title)
            XCTAssertEqual(candidate.sourceAssetIdentifier, entry.sourceID)
            let schedules = try context.fetch(FetchDescriptor<Schedule>(predicate: #Predicate { $0.sourceCandidateID == id }))
            XCTAssertEqual(Set(schedules.map(\.id)), Set(entry.scheduleIDs))
            XCTAssertTrue(schedules.allSatisfy { $0.title == entry.title && $0.sourceAssetIdentifier == entry.sourceID })
            deleteCandidates.append(candidate); deleteSchedules.append(contentsOf: schedules)
        }
        // XCTest assertions above are also enforced by a non-assertion mutation guard.
        guard deleteCandidates.count == owned.count,
              zip(owned, deleteCandidates).allSatisfy({ entry, candidate in
                  allowed.contains(entry.title) && candidate.title == entry.title
                      && candidate.sourceAssetIdentifier == entry.sourceID && entry.sourceID != originalSource
              }), Set(deleteSchedules.map(\.id)) == Set(owned.flatMap(\.scheduleIDs)) else {
            throw NSError(domain: "Task38CleanupIdentityMismatch", code: 1)
        }
        for schedule in deleteSchedules { context.delete(schedule) }
        for candidate in deleteCandidates { context.delete(candidate) }
        do { try context.save() } catch { context.rollback(); throw error }
        let remainingSchedules = try context.fetch(FetchDescriptor<Schedule>())
        _ = try WidgetSnapshotStore().write(schedules: remainingSchedules)
        let authorization = NotificationAuthorizationService()
        await authorization.refresh()
        _ = await NotificationScheduler().synchronize(schedules: remainingSchedules, access: authorization.access)
        let originalTitle = "Task38 테스트"
        let original = try XCTUnwrap(remainingSchedules.first { $0.title == originalTitle })
        XCTAssertEqual(original.id.uuidString, "244593CC-077B-45EA-804C-33FD9BA26AA4")
        XCTAssertEqual(original.date, CalendarDate(year: 2026, month: 10, day: 5))
        XCTAssertEqual(original.time, ClockTime(hour: 16, minute: 0))
        XCTAssertEqual(original.timeZoneIdentifier, "US/Pacific")
        XCTAssertTrue(original.notifyDayBefore && original.notifySameDay)
        XCTAssertEqual(original.calendarExportStatus, .succeeded)
        let restoredCandidates = try context.fetch(FetchDescriptor<ScheduleCandidate>(predicate: #Predicate { $0.sourceAssetIdentifier == originalSource }))
        XCTAssertEqual(restoredCandidates.count, 2)
        XCTAssertTrue(restoredCandidates.allSatisfy { $0.reviewStatus == .pending && $0.registeredScheduleID == nil })
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let removedIDs = Set(owned.flatMap(\.scheduleIDs))
        XCTAssertFalse(pending.contains { request in
            NotificationPayload.scheduleID(from: request.content.userInfo).map { removedIDs.contains($0) } ?? false
        })
        print("[Task38 authorized cleanup] removedCandidates=\(deleteCandidates.count) removedSchedules=\(deleteSchedules.count) originalCandidates2Schedule1Preserved=true ownedPendingRemoved=true sourcePhotosNotesCalendarNotMutated=true")
        #endif
    }
}

@MainActor final class DeviceNotificationQueueIntegrationTests: XCTestCase {
    func testRealQueueRegisterEditDeletePreservesOtherRequests() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone notification queue only")
        #else
        let system = UNUserNotificationCenter.current()
        var access = NotificationAuthorizationAccess(systemStatus: await system.notificationSettings().authorizationStatus)
        // Explicit USB validation setup only; ordinary runs remain prompt-free.
        if access == .notDetermined,
           ProcessInfo.processInfo.environment["TASK38_REQUEST_NOTIFICATION_PERMISSION"] == "1" {
            let authorization = NotificationAuthorizationService()
            access = await authorization.requestAuthorizationIfNeeded(remindersEnabled: true).access
            print("[Task38 device permission setup] notificationAccess=\(access)")
        }
        guard access.allowsScheduling else { throw XCTSkip("Existing device notification permission does not allow scheduling; no permission prompt") }
        let now = Date(), zone = TimeZone.current
        let day = CalendarDate.gregorianDate(from: now.addingTimeInterval(3 * 86_400), timeZone: zone)
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "task38-bundle-only", sourceCandidateKey: UUID().uuidString,
            evidenceText: "Synthetic only", title: "SnapSchedule Task38 synthetic queue", date: day,
            time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: zone.identifier,
            notifyDayBefore: true, notifySameDay: true)
        context.insert(candidate); try context.save()
        let result = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}).register(candidateIDs: [candidate.id])
        let id = try XCTUnwrap(result.scheduleIDs.first)
        // Scope every OS mutation to this fresh synthetic schedule UUID.
        let center = DeviceScopedNotificationCenter(system: system, scheduleID: id)
        defer { system.removePendingNotificationRequests(withIdentifiers: Array(center.ownedRequestIDs)) }
        let before = Set(await system.pendingNotificationRequests().map(\.identifier))
        let scheduler = NotificationScheduler(center: center, now: { now })
        var schedules = try context.fetch(FetchDescriptor<Schedule>())
        let registered = await scheduler.synchronize(schedules: schedules, access: access)
        XCTAssertEqual(registered.scheduledCount, 2)
        let actualRegistered = await system.pendingNotificationRequests().filter { center.owns($0) }
        XCTAssertEqual(actualRegistered.count, 2)
        XCTAssertTrue(actualRegistered.allSatisfy { NotificationPayload.scheduleID(from: $0.content.userInfo) == id })
        XCTAssertTrue(actualRegistered.allSatisfy { $0.trigger is UNCalendarNotificationTrigger })
        let schedule = try XCTUnwrap(schedules.first)
        var draft = ScheduleEditDraft(schedule: schedule); draft.notifyDayBefore = false; draft.title = "SnapSchedule Task38 edited synthetic queue"
        let mutations = ScheduleMutationService(context: context, widgetSnapshotRefresh: {})
        _ = try mutations.update(scheduleID: id, draft: draft)
        schedules = try context.fetch(FetchDescriptor<Schedule>())
        let edited = await scheduler.synchronize(schedules: schedules, access: access)
        XCTAssertEqual(edited.scheduledCount, 1)
        let actualEdited = await system.pendingNotificationRequests().filter { center.owns($0) }
        XCTAssertEqual(actualEdited.count, 1)
        XCTAssertTrue(actualEdited.first?.content.title.contains("edited synthetic queue") == true)
        _ = try mutations.delete(scheduleID: id)
        let deleted = await scheduler.synchronize(schedules: try context.fetch(FetchDescriptor<Schedule>()), access: access)
        XCTAssertEqual(deleted.scheduledCount, 0)
        let after = await system.pendingNotificationRequests()
        XCTAssertFalse(after.contains { center.owns($0) })
        XCTAssertEqual(Set(after.map(\.identifier)), before)
        print("[Task38 device real queue] registered=2 edited=1 deleted=0 unrelatedPreserved=\(before.count); no banner observation")
        #endif
    }
}

@MainActor private final class DeviceScopedNotificationCenter: NotificationCenterScheduling {
    let system: UNUserNotificationCenter
    let scheduleID: UUID
    var ownedRequestIDs = Set<String>()
    init(system: UNUserNotificationCenter, scheduleID: UUID) { self.system = system; self.scheduleID = scheduleID }
    func owns(_ request: UNNotificationRequest) -> Bool { NotificationPayload.scheduleID(from: request.content.userInfo) == scheduleID }
    func pendingRequests() async -> [UNNotificationRequest] { await system.pendingNotificationRequests().filter(owns) }
    func add(_ request: UNNotificationRequest) async throws {
        guard owns(request) else { throw IntegrationError.save }
        ownedRequestIDs.insert(request.identifier)
        try await system.add(request)
    }
    func removePendingRequests(withIdentifiers identifiers: [String]) {
        system.removePendingNotificationRequests(withIdentifiers: identifiers.filter { ownedRequestIDs.contains($0) })
    }
}

/// Records actual callback arrival without blocking or delaying PhotoKit.
private final class Task38RealPhotoKitBoundaryState: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackArrived = false
    var callbackHasArrived: Bool { lock.withLock { callbackArrived } }
    func markCallback() { lock.withLock { callbackArrived = true } }
}

@MainActor private final class BatchCalendarWriter: CalendarEventWriting {
    var access = CalendarAuthorizationAccess.writeOnly
    var fail = true
    private var written = 0
    func requestWriteOnlyAccess() async throws -> CalendarAuthorizationAccess { access }
    func save(_ event: CalendarEventDraft) throws -> String? {
        if fail { throw IntegrationError.save }
        written += 1
        return "batch-event-\(written)"
    }
}
