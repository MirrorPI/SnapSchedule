import ImageIO
import Observation
import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class ScanCoordinatorTests: XCTestCase {
    func testTwoContestCapturesCreateTwoDeadlinesWithoutChangingOldCandidatesOrSchedules() async throws {
        let captures = [asset("new-film", createdAt: 100), asset("new-photo", createdAt: 200)]
        let h = try makeHarness(discoveries: [captures, captures], load: { id, _ in
            ScreenshotImageInput(data: Data(id.utf8), orientation: .up)
        }, recognize: { input in
            let film = String(decoding: input.data, as: UTF8.self) == "new-film"
            return [
                RecognizedTextFragment(text: film ? "7th Da-Ho Award Short Film Competition" : "LG 대국민 미소 사진 공모전 - 스마일 모먼트", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.04), confidence: 1),
                RecognizedTextFragment(text: film ? "접수기간 2026-08-01 ~ 2027-01-15 D-100" : "2026.09.23 - 10.18", boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.04), confidence: 1),
            ]
        })
        let oldCandidates = (0..<5).map { index in
            ScheduleCandidate(sourceAssetIdentifier: "old-\(index % 2)", sourceCandidateKey: "old-\(index)",
                evidenceText: "UNCHANGED OLD EVIDENCE", title: "Old \(index)",
                date: CalendarDate(year: 2026, month: 10, day: index + 1))
        }
        oldCandidates.forEach { h.context.insert($0) }
        let oldScan = ScreenshotScan(assetIdentifier: "old-0", status: .completed)
        oldScan.analysisVersion = "preserved-old-version"
        let oldSchedule = Schedule(sourceCandidateID: UUID(), title: "Old registered schedule",
            date: CalendarDate(year: 2026, month: 10, day: 1), sourceAssetIdentifier: "old-registered")
        h.context.insert(oldScan); h.context.insert(oldSchedule); try h.context.save()
        await h.coordinator.activate(access: .authorized)
        let candidates = try h.context.fetch(FetchDescriptor<ScheduleCandidate>())
        let created = candidates.filter { $0.sourceAssetIdentifier.hasPrefix("new-") }
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created.first { $0.sourceAssetIdentifier == "new-film" }?.date, CalendarDate(year: 2027, month: 1, day: 15))
        XCTAssertEqual(created.first { $0.sourceAssetIdentifier == "new-photo" }?.date, CalendarDate(year: 2026, month: 10, day: 18))
        XCTAssertTrue(created.allSatisfy(\.isRegistrationEligible))
        XCTAssertEqual(h.coordinator.status.targetImageCount, 2)
        XCTAssertEqual(h.coordinator.status.pendingCandidateCount, 4, "Old five records remain on two photos; two new photo candidates are added")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Schedule>()), 1, "Analysis cannot register schedules")
        await h.coordinator.activate(access: .authorized)
        XCTAssertEqual(Set(h.loadedIdentifiers.values), Set(["new-film", "new-photo"]))
        XCTAssertEqual(h.loadedIdentifiers.values.count, 2, "Completed captures are not reanalyzed")
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 7)
        let registration = ScheduleRegistrationService(context: h.context, widgetSnapshotRefresh: {})
        let result = try registration.register(candidateIDs: Set(created.map(\.id)))
        XCTAssertEqual(result.scheduleIDs.count, 2)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Schedule>()), 3)
        XCTAssertThrowsError(try registration.register(candidateIDs: Set(created.map(\.id))))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Schedule>()), 3)
        for (index, old) in oldCandidates.enumerated() {
            XCTAssertEqual(old.reviewStatus, .pending); XCTAssertNil(old.registeredScheduleID)
            XCTAssertEqual(old.title, "Old \(index)"); XCTAssertEqual(old.evidenceText, "UNCHANGED OLD EVIDENCE")
            XCTAssertEqual(old.date, CalendarDate(year: 2026, month: 10, day: index + 1))
        }
        XCTAssertEqual(oldScan.status, .completed); XCTAssertEqual(oldScan.analysisVersion, "preserved-old-version")
        XCTAssertEqual(oldSchedule.title, "Old registered schedule")
    }

    func testUndatedScreenCompletesWithoutCandidatesAndIsNotAnalyzedOnReactivation() async throws {
        let h = try makeHarness(
            discoveries: [[asset("chat", createdAt: 100)], [asset("chat", createdAt: 100)]],
            load: { id, _ in ScreenshotImageInput(data: Data(id.utf8), orientation: .up) },
            recognize: { _ in [self.fragment("Chat 14:00")] }
        )
        await h.coordinator.activate(access: .authorized)
        XCTAssertEqual(h.coordinator.status.state, .completed)
        XCTAssertEqual(h.coordinator.status.completedImageCount, 1)
        XCTAssertEqual(h.coordinator.status.failedImageCount, 0)
        XCTAssertEqual(h.coordinator.status.excludedUndatedDraftCount, 1)
        XCTAssertEqual(h.coordinator.status.excludedAppScreenImageCount, 0)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 0)
        await h.coordinator.activate(access: .authorized)
        XCTAssertEqual(h.loadedIdentifiers.values, ["chat"])
        XCTAssertEqual(h.coordinator.status.pendingCandidateCount, 0)
    }

    func testActivationPreservesLegacyUndatedPendingCandidatesWithoutDeletingData() async throws {
        let h = try makeHarness(discoveries: [[], []], load: { _, _ in
            throw ScreenshotImageLoadError.inaccessible
        }, recognize: { _ in [] })
        let undated = ScheduleCandidate(sourceAssetIdentifier: "old", sourceCandidateKey: "time",
                                        title: "Chat", time: ClockTime(hour: 14, minute: 0))
        let dated = ScheduleCandidate(sourceAssetIdentifier: "old", sourceCandidateKey: "date",
                                      title: "Meeting", date: CalendarDate(year: 2026, month: 10, day: 3))
        let registered = ScheduleCandidate(sourceAssetIdentifier: "old", sourceCandidateKey: "registered",
                                           title: "Registered", reviewStatus: .registered)
        let schedule = Schedule(sourceCandidateID: registered.id, title: "Registered",
                                date: CalendarDate(year: 2026, month: 10, day: 3), sourceAssetIdentifier: "old")
        registered.registeredScheduleID = schedule.id
        let scan = ScreenshotScan(assetIdentifier: "old", status: .completed)
        h.context.insert(undated); h.context.insert(dated); h.context.insert(registered)
        h.context.insert(schedule); h.context.insert(scan)
        try h.context.save()
        await h.coordinator.activate(access: .denied)
        XCTAssertEqual(undated.reviewStatus, .pending)
        XCTAssertEqual(h.coordinator.status.dismissedUndatedCandidateCount, 0)
        let reloaded = ModelContext(h.context.container)
        XCTAssertEqual(try reloaded.fetch(FetchDescriptor<ScheduleCandidate>())
            .first { $0.id == undated.id }?.reviewStatus, .pending)
        XCTAssertEqual(dated.reviewStatus, .pending)
        XCTAssertEqual(registered.reviewStatus, .registered)
        XCTAssertEqual(registered.registeredScheduleID, schedule.id)
        XCTAssertEqual(scan.status, .completed)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 3)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Schedule>()), 1)
        await h.coordinator.activate(access: .authorized)
        XCTAssertEqual(h.coordinator.status.pendingCandidateCount, 1)
        XCTAssertEqual(h.coordinator.status.dismissedUndatedCandidateCount, 0)
        XCTAssertEqual(undated.reviewStatus, .pending)
    }

    func testOwnScheduleDetailsAreExcludedInAllSupportedLanguages() async throws {
        for labels in [
            ["Calendar copy", "View Original Screenshot", "Delete Schedule"],
            ["캘린더 사본", "원본 스크린샷 보기", "일정 삭제"],
            ["カレンダーのコピー", "元のスクリーンショットを表示", "予定を削除"],
        ] {
            let h = try makeHarness(
                discoveries: [[asset("own", createdAt: 100)]],
                load: { id, _ in ScreenshotImageInput(data: Data(id.utf8), orientation: .up) },
                recognize: { _ in (["Meeting 2026-10-03 14:00"] + labels).map(self.fragment) }
            )
            await h.coordinator.activate(access: .authorized)
            XCTAssertEqual(h.coordinator.status.state, .completed)
            XCTAssertEqual(h.coordinator.status.completedImageCount, 1)
            XCTAssertEqual(h.coordinator.status.excludedAppScreenImageCount, 1)
            XCTAssertEqual(h.coordinator.status.excludedAppScreenDraftCount, 1)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 0)
            XCTAssertEqual(try h.context.fetch(FetchDescriptor<ScreenshotScan>()).first?.hasDateCandidates, false)
        }
    }

    func testExternalRegisteredEventAndIsolatedAppWordsRemainReviewCandidates() async throws {
        let h = try makeHarness(
            discoveries: [[asset("external", createdAt: 100)]],
            load: { id, _ in ScreenshotImageInput(data: Data(id.utf8), orientation: .up) },
            recognize: { _ in [self.fragment("Meeting 2026-10-03 14:00"), self.fragment("Delete Schedule")] }
        )
        h.context.insert(Schedule(sourceCandidateID: UUID(), title: "Meeting",
                                  date: CalendarDate(year: 2026, month: 10, day: 3),
                                  time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul",
                                  sourceAssetIdentifier: "original"))
        try h.context.save()
        await h.coordinator.activate(access: .authorized)
        let candidates = try h.context.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.date, CalendarDate(year: 2026, month: 10, day: 3))
    }

    func testReviewableDateExpressionsSurviveAlongsideUndatedFragments() async throws {
        let h = try makeHarness(
            discoveries: [[asset("real", createdAt: 1_791_000_000)]],
            load: { id, _ in ScreenshotImageInput(data: Data(id.utf8), orientation: .up) },
            recognize: { _ in ["내일 회의", "금요일 상담", "10/3 예약", "Chat 14:00"].map(self.fragment) }
        )
        await h.coordinator.activate(access: .authorized)
        let candidates = try h.context.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].recognizedDateOptions.count, 3)
        XCTAssertTrue(candidates.allSatisfy { $0.date != nil && $0.requiresReview })
        XCTAssertEqual(h.coordinator.status.excludedUndatedDraftCount, 1)
        XCTAssertEqual(h.coordinator.status.pendingCandidateCount, 1)
    }

    func testCroppedDetailNeedsRegisteredTitleDateTimeAndAppOptionsToExclude() async throws {
        for registeredHour in [14, 15] {
            let h = try makeHarness(
                discoveries: [[asset("crop", createdAt: 100)]],
                load: { id, _ in ScreenshotImageInput(data: Data(id.utf8), orientation: .up) },
                recognize: { _ in ["Meeting", "2026-10-03", "14:00", "Calendar copy", "One day before", "On the day"].map(self.fragment) }
            )
            h.context.insert(Schedule(sourceCandidateID: UUID(), title: "Meeting",
                                      date: CalendarDate(year: 2026, month: 10, day: 3),
                                      time: ClockTime(hour: registeredHour, minute: 0), timeZoneIdentifier: "Asia/Seoul",
                                      sourceAssetIdentifier: "original"))
            try h.context.save()
            await h.coordinator.activate(access: .authorized)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), registeredHour == 14 ? 0 : 1)
            XCTAssertEqual(h.coordinator.status.excludedAppScreenImageCount, registeredHour == 14 ? 1 : 0)
        }
    }

    func testLowConfidenceOrQuotedAppLabelsDoNotExcludeRealDates() async throws {
        for quoted in [false, true] {
            let h = try makeHarness(
                discoveries: [[asset("uncertain", createdAt: 100)]],
                load: { id, _ in ScreenshotImageInput(data: Data(id.utf8), orientation: .up) },
                recognize: { _ in
                    [self.fragment("Conference 2026-10-03")] +
                        ["Calendar copy", "View Original Screenshot", "Delete Schedule"].map { text in
                            RecognizedTextFragment(text: quoted ? "How to use: " + text : text,
                                                   boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1),
                                                   confidence: quoted ? 0.99 : 0.5)
                        }
                }
            )
            await h.coordinator.activate(access: .authorized)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 1)
            XCTAssertEqual(h.coordinator.status.excludedAppScreenImageCount, 0)
        }
    }

    func testClearHomeAndCandidateReviewScreensAreExcluded() async throws {
        for labels in [
            ["Screenshot analysis", "Candidate review", "Review candidates"],
            ["View Original Screenshot", "Include date", "Include time", "Add to Calendar after registration"],
            ["View Original Screenshot", "Notify one day before", "Notify on the day", "Add to Calendar after registration"],
            ["원본 스크린샷 보기", "하루 전 알림", "당일 알림", "등록 후 캘린더에 추가"],
            ["元のスクリーンショットを表示", "前日に通知", "当日に通知", "登録後にカレンダーに追加"],
        ] {
            let h = try makeHarness(
                discoveries: [[asset("app", createdAt: 100)], [asset("app", createdAt: 100)]],
                load: { id, _ in ScreenshotImageInput(data: Data(id.utf8), orientation: .up) },
                recognize: { _ in (["Meeting 2026-10-03"] + labels).map(self.fragment) }
            )
            await h.coordinator.activate(access: .authorized)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 0)
            XCTAssertEqual(h.coordinator.status.excludedAppScreenImageCount, 1)
            await h.coordinator.activate(access: .authorized)
            XCTAssertEqual(h.loadedIdentifiers.values, ["app"])
        }
    }

    func testCancellationDuringFirstDiscoveryKeepsBaselineForRelaunch() async throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        let suiteName = "ScanCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        let discoveryGate = AsyncGate()
        let baseline = Date(timeIntervalSince1970: 1_000)
        let coordinator = ScanCoordinator(
            context: context,
            settings: settings,
            discover: { _ in
                await discoveryGate.wait()
                return .authorized([])
            },
            loadImage: { identifier, _ in
                XCTFail("Unexpected image load for \(identifier)")
                throw ScreenshotImageLoadError.inaccessible
            },
            recognizeText: { _ in [] },
            analysisDate: { baseline }
        )

        let activation = Task { await coordinator.activate(access: .authorized) }
        await waitUntil { coordinator.status.state == .discovering }
        coordinator.cancel()

        XCTAssertEqual(settings.screenshotAnalysisBaselineDate, baseline)
        XCTAssertEqual(
            AppSettings(userDefaults: defaults).screenshotAnalysisBaselineDate,
            baseline
        )

        await discoveryGate.open()
        await activation.value
        XCTAssertEqual(coordinator.status.state, .waiting)
    }

    func testFirstReadableActivationPersistsBaselineBeforeDiscoveryCompletes() async throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        let suiteName = "ScanCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        let discoveryGate = AsyncGate()
        let loadedIdentifiers = LockedValue<[String]>([])
        let baseline = Date(timeIntervalSince1970: 1_000)
        let coordinator = ScanCoordinator(
            context: context,
            settings: settings,
            discover: { _ in
                await discoveryGate.wait()
                return .authorized([self.asset("captured-during-discovery", createdAt: 1_001)])
            },
            loadImage: { identifier, _ in
                loadedIdentifiers.withValue { $0.append(identifier) }
                return ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognizeText: { _ in [] },
            analysisDate: { baseline },
            timeZone: { TimeZone(identifier: "Asia/Seoul")! },
            analysisVersion: "baseline-race-test"
        )

        let activation = Task { await coordinator.activate(access: .authorized) }
        await waitUntil { coordinator.status.state == .discovering }

        XCTAssertEqual(settings.screenshotAnalysisBaselineDate, baseline)

        await discoveryGate.open()
        await activation.value
        XCTAssertEqual(loadedIdentifiers.values, ["captured-during-discovery"])
    }

    func testFirstReadableActivationEstablishesBaselineWithoutAnalyzingExistingScreenshots() async throws {
        let harness = try makeHarness(
            discoveries: [[
                asset("existing", createdAt: 100),
                ScreenshotAssetMetadata(
                    assetIdentifier: "unknown-date",
                    creationDate: nil,
                    pixelWidth: 100,
                    pixelHeight: 200
                ),
            ]],
            load: { identifier, _ in
                XCTFail("Existing screenshot should not be loaded: \(identifier)")
                throw ScreenshotImageLoadError.inaccessible
            },
            recognize: { _ in [] },
            initialBaseline: nil,
            analysisDate: Date(timeIntervalSince1970: 1_000)
        )

        await harness.coordinator.activate(access: .authorized)

        XCTAssertEqual(
            harness.settings.screenshotAnalysisBaselineDate,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(harness.loadedIdentifiers.values.isEmpty)
        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 0)
        XCTAssertTrue(try scanStatuses(in: harness.context).isEmpty)
    }

    func testLaterActivationAnalyzesOnlyScreenshotsCapturedAfterPersistedBaseline() async throws {
        let harness = try makeHarness(
            discoveries: [[
                asset("older", createdAt: 999),
                asset("newer", createdAt: 1_001),
            ]],
            load: { identifier, _ in
                ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { _ in [] },
            initialBaseline: Date(timeIntervalSince1970: 1_000)
        )

        await harness.coordinator.activate(access: .limited)

        XCTAssertEqual(harness.loadedIdentifiers.values, ["newer"])
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 1)
        XCTAssertEqual(try scanStatuses(in: harness.context), ["newer": .completed])
    }

    func testActivationProcessesImagesSequentiallyAndCountsImagesSeparatelyFromCandidates() async throws {
        let harness = try makeHarness(
            discoveries: [[asset("first", createdAt: 100), asset("second", createdAt: 200)]],
            load: { identifier, _ in
                ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { input in
                let identifier = String(decoding: input.data, as: UTF8.self)
                return identifier == "first"
                    ? [self.fragment("2026-10-03 14:00 Team sync")]
                    : [self.fragment("No date here")]
            }
        )

        await harness.coordinator.activate(access: .authorized)

        XCTAssertEqual(Set(harness.loadedIdentifiers.values), Set(["first", "second"]))
        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 2)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 2)
        XCTAssertEqual(harness.coordinator.status.failedImageCount, 0)
        XCTAssertEqual(harness.coordinator.status.pendingImageCount, 0)
        XCTAssertEqual(harness.coordinator.status.pendingCandidateCount, 1)
        XCTAssertEqual(try scanStatuses(in: harness.context), ["first": .completed, "second": .completed])
    }

    func testOneImageFailureDoesNotStopBatchAndRetriesOnNextActivation() async throws {
        let attempts = LockedValue<[String: Int]>([:])
        let harness = try makeHarness(
            discoveries: [
                [asset("first", createdAt: 100), asset("second", createdAt: 200)],
                [asset("first", createdAt: 100), asset("second", createdAt: 200)],
            ],
            load: { identifier, _ in
                let attempt = attempts.withValue { value in
                    value[identifier, default: 0] += 1
                    return value[identifier]!
                }
                if identifier == "first", attempt == 1 {
                    throw ScreenshotImageLoadError.retryable(.local)
                }
                return ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { _ in [] }
        )

        await harness.coordinator.activate(access: .authorized)

        XCTAssertEqual(harness.coordinator.status.state, .completedWithFailures)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.failedImageCount, 1)
        XCTAssertEqual(Set(harness.loadedIdentifiers.values), Set(["first", "second"]))
        XCTAssertEqual(try scanStatuses(in: harness.context)["first"], .retryableFailure)
        XCTAssertEqual(try scanStatuses(in: harness.context)["second"], .completed)

        await harness.coordinator.activate(access: .authorized)

        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.failedImageCount, 0)
        XCTAssertEqual(harness.loadedIdentifiers.values.filter { $0 == "first" }.count, 2)
        XCTAssertEqual(harness.loadedIdentifiers.values.filter { $0 == "second" }.count, 1)
        XCTAssertEqual(try scanStatuses(in: harness.context)["first"], .completed)
    }

    func testActivationDuringAnalysisQueuesNewDiscoveryForStableNextBatch() async throws {
        let gate = AsyncGate()
        let harness = try makeHarness(
            discoveries: [
                [asset("first", createdAt: 100)],
                [asset("first", createdAt: 100), asset("new", createdAt: 200)],
            ],
            load: { identifier, _ in
                if identifier == "first" {
                    await gate.wait()
                }
                return ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { _ in [] }
        )

        let firstActivation = Task { await harness.coordinator.activate(access: .authorized) }
        await waitUntil { harness.coordinator.status.state == .analyzing }
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.pendingImageCount, 1)

        let repeatedActivation = Task { await harness.coordinator.activate(access: .authorized) }
        await Task.yield()
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 1)
        XCTAssertEqual(harness.loadedIdentifiers.values, ["first"])

        await gate.open()
        await firstActivation.value
        await repeatedActivation.value

        XCTAssertEqual(harness.loadedIdentifiers.values, ["first", "new"])
        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 1)
        XCTAssertEqual(try scanStatuses(in: harness.context), ["first": .completed, "new": .completed])
    }

    func testUnavailableAccessPublishesRestrictionWithoutLoadingImages() async throws {
        let harness = try makeHarness(
            discoveries: [[]],
            load: { identifier, _ in
                XCTFail("Unexpected image load for \(identifier)")
                throw ScreenshotImageLoadError.inaccessible
            },
            recognize: { _ in [] }
        )

        await harness.coordinator.activate(access: .denied)

        XCTAssertEqual(harness.coordinator.status.state, .accessUnavailable)
        XCTAssertEqual(harness.coordinator.status.photoAccess, .denied)
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 0)
        XCTAssertTrue(harness.loadedIdentifiers.values.isEmpty)
    }

    func testAuthorizedEmptyLibraryCompletesWithoutImageWork() async throws {
        let harness = try makeHarness(
            discoveries: [[]],
            load: { identifier, _ in
                XCTFail("Unexpected image load for \(identifier)")
                throw ScreenshotImageLoadError.inaccessible
            },
            recognize: { _ in [] }
        )

        await harness.coordinator.activate(access: .authorized)

        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 0)
        XCTAssertEqual(harness.coordinator.status.pendingImageCount, 0)
    }

    func testCancellationPreservesInterruptedImageForNextActivation() async throws {
        let gate = AsyncGate()
        let attempts = LockedValue(0)
        let visibleAsset = asset("interrupted", createdAt: 100)
        let recognizedIdentifiers = LockedValue<[String]>([])
        let harness = try makeHarness(
            discoveries: [[visibleAsset], [visibleAsset]],
            load: { identifier, report in
                let attempt = attempts.withValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    report(.downloadingFromICloud(progress: 0.25))
                    await gate.wait()
                }
                return ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { input in
                recognizedIdentifiers.withValue { $0.append(String(decoding: input.data, as: UTF8.self)) }
                return []
            }
        )

        let activation = Task { await harness.coordinator.activate(access: .authorized) }
        await waitUntil { harness.coordinator.status.imageLoadPhase == .downloadingFromICloud(progress: 0.25) }
        harness.coordinator.cancel()
        await gate.open()
        await activation.value

        XCTAssertEqual(harness.coordinator.status.state, .waiting)
        XCTAssertNil(harness.coordinator.status.currentAssetIdentifier)
        XCTAssertNil(harness.coordinator.status.imageLoadPhase)
        XCTAssertEqual(harness.coordinator.status.pendingImageCount, 1)
        XCTAssertTrue(recognizedIdentifiers.values.isEmpty, "Cancelled download must not enter OCR")
        XCTAssertEqual(try scanStatuses(in: harness.context)["interrupted"], .retryableFailure)

        await harness.coordinator.activate(access: .authorized)

        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertEqual(try scanStatuses(in: harness.context)["interrupted"], .completed)
        XCTAssertEqual(harness.loadedIdentifiers.values, ["interrupted", "interrupted"])
        XCTAssertEqual(recognizedIdentifiers.values, ["interrupted"])
    }

    func testReactivationWhileCancelledRunIsFinishingStartsRecoveryBatch() async throws {
        let gate = AsyncGate()
        let attempts = LockedValue(0)
        let visibleAsset = asset("interrupted", createdAt: 100)
        let harness = try makeHarness(
            discoveries: [[visibleAsset], [visibleAsset]],
            load: { identifier, _ in
                let attempt = attempts.withValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    await gate.wait()
                }
                return ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { _ in [] }
        )

        let interruptedActivation = Task {
            await harness.coordinator.activate(access: .authorized)
        }
        await waitUntil { harness.coordinator.status.state == .analyzing }
        harness.coordinator.cancel()
        let resumedActivation = Task {
            await harness.coordinator.activate(access: .authorized)
        }
        await gate.open()
        await interruptedActivation.value
        await resumedActivation.value

        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertEqual(try scanStatuses(in: harness.context)["interrupted"], .completed)
        XCTAssertEqual(harness.loadedIdentifiers.values, ["interrupted", "interrupted"])
    }

    func testLargeBatchProcessesEveryImageSequentiallyWithoutOmission() async throws {
        let assets = (0..<100).map {
            asset(String(format: "asset-%03d", $0), createdAt: TimeInterval($0))
        }
        let harness = try makeHarness(
            discoveries: [assets],
            load: { identifier, _ in
                ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { _ in [] }
        )

        await harness.coordinator.activate(access: .authorized)

        XCTAssertEqual(harness.coordinator.status.targetImageCount, 100)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 100)
        XCTAssertEqual(harness.coordinator.status.failedImageCount, 0)
        XCTAssertEqual(harness.coordinator.status.pendingImageCount, 0)
        XCTAssertEqual(Set(harness.loadedIdentifiers.values).count, 100)
        XCTAssertEqual(try scanStatuses(in: harness.context).values.filter { $0 == .completed }.count, 100)
    }

    func testICloudFailureRetriesOnlyUnfinishedImageAndKeepsBatchSeparateFromCandidates() async throws {
        let gate = AsyncGate()
        let attempts = LockedValue<[String: Int]>([:])
        let recognized = LockedValue<[String]>([])
        let assets = [asset("a-local", createdAt: 100), asset("b-cloud", createdAt: 200)]
        let harness = try makeHarness(
            discoveries: [assets, assets, assets],
            load: { identifier, report in
                let attempt = attempts.withValue { counts in
                    counts[identifier, default: 0] += 1
                    return counts[identifier]!
                }
                if identifier == "b-cloud" {
                    report(.downloadingFromICloud(progress: 0.25))
                    if attempt == 1 {
                        throw ScreenshotImageLoadError.retryable(.iCloud)
                    }
                    await gate.wait()
                }
                return ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { input in
                let identifier = String(decoding: input.data, as: UTF8.self)
                recognized.withValue { $0.append(identifier) }
                return [self.fragment("2026-10-03 14:00 Team sync")]
            }
        )

        await harness.coordinator.activate(access: .authorized)
        XCTAssertEqual(try scanStatuses(in: harness.context), ["a-local": .completed, "b-cloud": .retryableFailure])
        XCTAssertEqual(recognized.values, ["a-local"])
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 2)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.failedImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.pendingImageCount, 0)
        let savedCandidates = try harness.context.fetch(FetchDescriptor<ScheduleCandidate>()).map(\.id)
        XCTAssertEqual(savedCandidates.count, 1)

        let recovery = Task { await harness.coordinator.activate(access: .authorized) }
        await waitUntil { harness.coordinator.status.imageLoadPhase == .downloadingFromICloud(progress: 0.25) }
        XCTAssertEqual(try scanStatuses(in: harness.context), ["a-local": .completed, "b-cloud": .analyzing])
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 0)
        XCTAssertEqual(harness.coordinator.status.failedImageCount, 0)
        XCTAssertEqual(harness.coordinator.status.pendingImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.pendingCandidateCount, 1)
        XCTAssertEqual(recognized.values, ["a-local"])
        await gate.open()
        await recovery.value

        XCTAssertEqual(harness.loadedIdentifiers.values.sorted(), ["a-local", "b-cloud", "b-cloud"])
        XCTAssertEqual(recognized.values, ["a-local", "b-cloud"])
        XCTAssertEqual(harness.coordinator.status.completedImageCount, 1)
        XCTAssertEqual(harness.coordinator.status.pendingCandidateCount, 2)
        let recoveredCandidates = try harness.context.fetch(FetchDescriptor<ScheduleCandidate>()).map(\.id)
        XCTAssertEqual(recoveredCandidates.count, 2)
        XCTAssertTrue(Set(savedCandidates).isSubset(of: Set(recoveredCandidates)))

        await harness.coordinator.activate(access: .authorized)
        XCTAssertEqual(harness.coordinator.status.targetImageCount, 0)
        XCTAssertEqual(harness.coordinator.status.pendingCandidateCount, 2)
        XCTAssertEqual(recognized.values, ["a-local", "b-cloud"])
        XCTAssertEqual(try scanStatuses(in: harness.context), ["a-local": .completed, "b-cloud": .completed])
        XCTAssertEqual(Set(try harness.context.fetch(FetchDescriptor<ScheduleCandidate>()).map(\.id)), Set(recoveredCandidates))
    }

    func testRetryIgnoresLateICloudProgressFromPreviousAttemptForSameImage() async throws {
        let gate = AsyncGate()
        let attempts = LockedValue(0)
        let previousPhase = LockedValue<(@Sendable (ScreenshotImageLoadPhase) -> Void)?>(nil)
        let visibleAsset = asset("cloud", createdAt: 100)
        let harness = try makeHarness(
            discoveries: [[visibleAsset], [visibleAsset]],
            load: { identifier, report in
                let attempt = attempts.withValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    previousPhase.withValue { $0 = report }
                    throw ScreenshotImageLoadError.retryable(.iCloud)
                }
                report(.downloadingFromICloud(progress: 0.25))
                await gate.wait()
                return ScreenshotImageInput(data: Data(identifier.utf8), orientation: .up)
            },
            recognize: { _ in [] }
        )
        await harness.coordinator.activate(access: .authorized)
        let recovery = Task { await harness.coordinator.activate(access: .authorized) }
        await waitUntil { harness.coordinator.status.imageLoadPhase == .downloadingFromICloud(progress: 0.25) }

        let unexpectedProgress = XCTestExpectation(description: "Old attempt must not change retry progress")
        unexpectedProgress.isInverted = true
        let observing = LockedValue(true)
        withObservationTracking {
            _ = harness.coordinator.status.imageLoadPhase
        } onChange: {
            if observing.values { unexpectedProgress.fulfill() }
        }
        previousPhase.values?(.downloadingFromICloud(progress: 0.9))
        let result = await XCTWaiter.fulfillment(of: [unexpectedProgress], timeout: 0.2)
        observing.withValue { $0 = false }
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(harness.coordinator.status.imageLoadPhase, .downloadingFromICloud(progress: 0.25))
        await gate.open()
        await recovery.value
        XCTAssertEqual(harness.coordinator.status.state, .completed)
        XCTAssertNil(harness.coordinator.status.imageLoadPhase)
    }

    private func makeHarness(
        discoveries: [[ScreenshotAssetMetadata]],
        load: @escaping ScanCoordinator.LoadImage,
        recognize: @escaping ScanCoordinator.RecognizeText,
        initialBaseline: Date? = .distantPast,
        analysisDate: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws -> Harness {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        let remainingDiscoveries = LockedValue(discoveries)
        let loadedIdentifiers = LockedValue<[String]>([])
        let suiteName = "ScanCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)
        settings.screenshotAnalysisBaselineDate = initialBaseline
        let coordinator = ScanCoordinator(
            context: context,
            settings: settings,
            discover: { access in
                guard access.canReadAccessiblePhotos else { return .unavailable(access) }
                let assets = remainingDiscoveries.withValue { values in
                    values.isEmpty ? [] : values.removeFirst()
                }
                return access == .limited ? .limited(assets) : .authorized(assets)
            },
            loadImage: { identifier, report in
                loadedIdentifiers.withValue { $0.append(identifier) }
                return try await load(identifier, report)
            },
            recognizeText: recognize,
            analysisDate: { analysisDate },
            timeZone: { TimeZone(identifier: "Asia/Seoul")! },
            analysisVersion: "task-11-tests"
        )
        return Harness(
            coordinator: coordinator,
            context: context,
            settings: settings,
            loadedIdentifiers: loadedIdentifiers
        )
    }

    private func asset(_ identifier: String, createdAt: TimeInterval) -> ScreenshotAssetMetadata {
        ScreenshotAssetMetadata(
            assetIdentifier: identifier,
            creationDate: Date(timeIntervalSince1970: createdAt),
            pixelWidth: 100,
            pixelHeight: 200
        )
    }

    private func fragment(_ text: String) -> RecognizedTextFragment {
        RecognizedTextFragment(
            text: text,
            boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1),
            confidence: 0.9
        )
    }

    private func scanStatuses(in context: ModelContext) throws -> [String: ScreenshotScanStatus] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<ScreenshotScan>())
                .map { ($0.assetIdentifier, $0.status) }
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        attempts: Int = 100
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met")
    }

    private struct Harness {
        let coordinator: ScanCoordinator
        let context: ModelContext
        let settings: AppSettings
        let loadedIdentifiers: LockedValue<[String]>
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var values: Value {
        withValue { $0 }
    }

    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
