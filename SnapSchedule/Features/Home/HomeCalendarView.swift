import SwiftUI
import UIKit
import Observation

enum HomeCalendarPresentation {
    static func datesWithSchedules(_ schedules: [Schedule]) -> [CalendarDate] {
        sortedUnique(schedules.map(\.date))
    }

    static func datesNeedingDecorationReload(
        previous: [CalendarDate],
        current: [CalendarDate]
    ) -> [CalendarDate] {
        sortedUnique(
            previous.filter { !current.contains($0) }
                + current.filter { !previous.contains($0) }
        )
    }

    private static func sortedUnique(_ dates: [CalendarDate]) -> [CalendarDate] {
        dates
            .reduce(into: [CalendarDate]()) { dates, date in
                guard !dates.contains(date) else { return }
                dates.append(date)
            }
            .sorted(by: comesBefore)
    }

    static func schedules(
        on date: CalendarDate,
        from schedules: [Schedule],
        now: Date,
        deviceTimeZone: TimeZone
    ) -> [ScheduleDatePresentation] {
        let ordered = registeredSchedules(on: date, from: schedules)
        let presentations = ScheduleDatePresentation.sorted(ordered, now: now, deviceTimeZone: deviceTimeZone)
        let byID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
        return ordered.compactMap { byID[$0.id] }
    }

    static func registeredSchedules(on date: CalendarDate, from schedules: [Schedule]) -> [Schedule] {
        schedules.filter { $0.date == date }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func originalsByDate(_ schedules: [Schedule]) -> [CalendarDayOriginal] {
        datesWithSchedules(schedules).compactMap { date in
            let registered = registeredSchedules(on: date, from: schedules)
            guard let first = registered.first else { return nil }
            return CalendarDayOriginal(date: date, scheduleID: first.id,
                sourceAssetIdentifier: first.sourceAssetIdentifier, scheduleCount: registered.count,
                title: first.title)
        }
    }

    static func datesNeedingDecorationReload(previous: [CalendarDayOriginal], current: [CalendarDayOriginal]) -> [CalendarDate] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { (HomeCalendarView.DateKey($0.date), $0) })
        let new = Dictionary(uniqueKeysWithValues: current.map { (HomeCalendarView.DateKey($0.date), $0) })
        return sortedUnique(previous.map(\.date) + current.map(\.date)).filter {
            old[HomeCalendarView.DateKey($0)] != new[HomeCalendarView.DateKey($0)]
        }
    }

    private static func comesBefore(_ lhs: CalendarDate, _ rhs: CalendarDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

struct CalendarDayOriginal: Equatable {
    let date: CalendarDate
    let scheduleID: UUID
    let sourceAssetIdentifier: String
    let scheduleCount: Int
    let title: String
    var additionalCount: Int { max(0, scheduleCount - 1) }
    var accessibilityLabel: String {
        String(localized: "\(scheduleCount) registered schedules") + ", " + title
    }
}

struct HomeCalendarView: UIViewRepresentable {
    @Environment(\.screenshotCalendarThumbnailFactory) private var makeModel
    @Environment(\.scenePhase) private var scenePhase
    let originals: [CalendarDayOriginal]
    @Binding var selectedDate: CalendarDate
    let timeZone: TimeZone

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICalendarView {
        let calendarView = UICalendarView()
        calendarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(calendarView)
        calendarView.delegate = context.coordinator
        calendarView.selectionBehavior = UICalendarSelectionSingleDate(
            delegate: context.coordinator
        )
        context.coordinator.synchronizeSelection(in: calendarView, animated: false)
        return calendarView
    }

    func updateUIView(_ calendarView: UICalendarView, context: Context) {
        let previous = context.coordinator.originals
        let previousTimeZone = context.coordinator.timeZoneIdentifier
        context.coordinator.parent = self
        context.coordinator.originals = originals
        context.coordinator.timeZoneIdentifier = timeZone.identifier
        configure(calendarView)
        let datesToReload = previousTimeZone == timeZone.identifier
            ? HomeCalendarPresentation.datesNeedingDecorationReload(previous: previous, current: originals)
            : Array(Set((previous.map(\.date) + originals.map(\.date)).map(DateKey.init))).map(\.calendarDate)
        if !datesToReload.isEmpty {
            calendarView.reloadDecorations(
                forDateComponents: datesToReload.map { DateKey($0).dateComponents(calendar: calendar, timeZone: timeZone) },
                animated: false
            )
        }
        context.coordinator.decorations.allObjects.forEach { $0.setActive(scenePhase == .active) }

        context.coordinator.synchronizeSelection(in: calendarView, animated: false)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func configure(_ calendarView: UICalendarView) {
        calendarView.calendar = calendar
        calendarView.timeZone = timeZone
        calendarView.locale = .current
        calendarView.wantsDateDecorations = true
        calendarView.tintColor = SnapScheduleStyle.calendarUIColor
    }

    @MainActor
    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: HomeCalendarView
        var originals: [CalendarDayOriginal]
        let decorations = NSHashTable<CalendarOriginalDecorationView>.weakObjects()
        var timeZoneIdentifier: String

        init(parent: HomeCalendarView) {
            self.parent = parent
            originals = parent.originals
            timeZoneIdentifier = parent.timeZone.identifier
        }

        func calendarView(
            _ calendarView: UICalendarView,
            decorationFor dateComponents: DateComponents
        ) -> UICalendarView.Decoration? {
            guard let date = DateKey(dateComponents: dateComponents),
                  let original = originals.first(where: { $0.date == date.calendarDate }) else { return nil }
            return .customView { [weak self] in
                guard let self else { return UIView() }
                let decoration = CalendarOriginalDecorationView(original: original,
                    model: self.parent.makeModel(original.sourceAssetIdentifier))
                decoration.setActive(self.parent.scenePhase == .active)
                self.decorations.add(decoration)
                return decoration
            }
        }

        func dateSelection(
            _ selection: UICalendarSelectionSingleDate,
            didSelectDate dateComponents: DateComponents?
        ) {
            guard let dateComponents,
                  let date = DateKey(dateComponents: dateComponents) else {
                return
            }
            parent.selectedDate = date.calendarDate
        }

        func synchronizeSelection(in calendarView: UICalendarView, animated: Bool) {
            guard let selection = calendarView.selectionBehavior as? UICalendarSelectionSingleDate else {
                return
            }
            let desiredDate = DateKey(parent.selectedDate)
            guard selection.selectedDate.flatMap(DateKey.init(dateComponents:)) != desiredDate else {
                return
            }
            selection.setSelected(
                desiredDate.dateComponents(calendar: parent.calendar, timeZone: parent.timeZone),
                animated: animated
            )
        }
    }

    struct DateKey: Hashable {
        let year: Int
        let month: Int
        let day: Int

        init(_ date: CalendarDate) {
            year = date.year
            month = date.month
            day = date.day
        }

        init?(dateComponents: DateComponents) {
            guard let year = dateComponents.year,
                  let month = dateComponents.month,
                  let day = dateComponents.day else {
                return nil
            }
            self.year = year
            self.month = month
            self.day = day
        }

        var calendarDate: CalendarDate {
            CalendarDate(year: year, month: month, day: day)
        }

        func dateComponents(calendar: Calendar, timeZone: TimeZone) -> DateComponents {
            DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: year,
                month: month,
                day: day
            )
        }
    }
}

/// UIKit owns the compact date slot. Loading follows the visible decoration's lifetime.
@MainActor
final class CalendarOriginalDecorationView: UIView {
    private let model: ScreenshotPreviewModel
    private let imageView = UIImageView()
    private let countLabel = UILabel()
    private var isActive = true
    private let original: CalendarDayOriginal

    init(original: CalendarDayOriginal, model: ScreenshotPreviewModel) {
        self.original = original
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: original.additionalCount > 0
            ? CGSize(width: 38, height: 22) : CGSize(width: 24, height: 24)))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = original.accessibilityLabel
        accessibilityIdentifier = "calendar-original-\(original.date.year)-\(original.date.month)-\(original.date.day)"
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .secondaryLabel
        addSubview(imageView)
        countLabel.isHidden = original.additionalCount == 0
        countLabel.text = original.additionalCount > 0 ? "+\(original.additionalCount.formatted())" : nil
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        countLabel.textColor = .label
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.6
        addSubview(countLabel)
        observeModel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize {
        original.additionalCount > 0 ? CGSize(width: 38, height: 22) : CGSize(width: 24, height: 24)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let imageWidth = original.additionalCount > 0 ? min(18, bounds.width) : bounds.width
        imageView.frame = CGRect(x: 0, y: 0, width: imageWidth, height: bounds.height)
        countLabel.frame = CGRect(x: imageWidth + 2, y: 0, width: max(0, bounds.width - imageWidth - 2), height: bounds.height)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && isActive { model.load() } else { model.cancel() }
    }
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active && window != nil { model.load() } else { model.cancel() }
    }
    private func observeModel() {
        withObservationTracking {
            imageView.image = model.image ?? UIImage(systemName: model.status == .inaccessible || isRetryable
                ? "exclamationmark.triangle" : "photo")
            accessibilityLabel = original.accessibilityLabel + (model.status == .inaccessible || isRetryable
                ? ", " + String(localized: "Screenshot Unavailable") : "")
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }
    private var isRetryable: Bool {
        if case .retryable = model.status { return true }
        return false
    }
}
