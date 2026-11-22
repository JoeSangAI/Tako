// The owner's own Reminders and Calendar, the ladder's third rung. Nothing here asks the system for
// anything until the owner taps 接上 in the panel (`connect`); declined, it is never offered again. Once connected, what is read
// goes to the brain over the local connection and stays in its memory. By default it is only compared locally with the chats
// the owner has; the separate memory consent can also let the owner's model read it. Reminders: only those not yet done. Calendar:
// today's next day of meetings, only as moments (an invitation may be someone else's words, so never a source).
import EventKit
import Foundation
import QuartzCore

final class SystemSources {
    unowned let host: Controller
    private lazy var store = EKEventStore()   // made only once the owner connected, never just because Tako started
    private var observing = false, reading = false, lastRead: CFTimeInterval = -1000
    private let connectedKey = "systemSourcesConnected"

    init(_ host: Controller) { self.host = host }

    /// Full access to both, already given: read without asking anything.
    private var allowed: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess || EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// At launch: only if the owner connected them before and the system still allows it. No prompt can come from here.
    func start() {
        guard !host.selfTest, UserDefaults.standard.bool(forKey: connectedKey), allowed else { return }
        observe()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh(force: true) }
    }

    /// The owner tapped 接上: the system asks, once for each. Whatever they answer is told to the brain, which stops offering it.
    func connect() {
        guard !host.selfTest else { return }
        Task { @MainActor in
            let reminders = (try? await store.requestFullAccessToReminders()) ?? false
            let events = (try? await store.requestFullAccessToEvents()) ?? false
            let yes = reminders || events
            UserDefaults.standard.set(yes, forKey: connectedKey)
            host.post(path: "/ladder/sources", body: ["access": yes ? "connected" : "declined"]) { _ in }
            if yes { observe(); refresh(force: true) }
        }
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh(force: true) }
    }

    /// Read again: on a change in the store, on start, and when the brain's one timer wakes (at most every five minutes then).
    func refresh(force: Bool = false) {
        guard !host.selfTest, host.url != nil, UserDefaults.standard.bool(forKey: connectedKey), allowed, !reading else { return }
        guard force || CACurrentMediaTime() - lastRead > 300 else { return }
        reading = true; lastRead = CACurrentMediaTime()
        let now = Date()
        var events: [[String: Any]] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let span = store.predicateForEvents(withStart: now.addingTimeInterval(-600), end: now.addingTimeInterval(86400), calendars: nil)
            events = store.events(matching: span).filter { !$0.isAllDay }.map { event in
                ["id": event.eventIdentifier ?? "", "title": event.title ?? "", "start": event.startDate.timeIntervalSince1970,
                 "attendees": (event.attendees ?? []).compactMap { $0.name }]
            }
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { send([], events); return }
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { [weak self] found in
            let reminders: [[String: Any]] = (found ?? []).map { ["id": $0.calendarItemIdentifier, "title": $0.title ?? "", "notes": $0.notes ?? ""] }
            DispatchQueue.main.async { self?.send(reminders, events) }
        }
    }

    private func send(_ reminders: [[String: Any]], _ events: [[String: Any]]) {
        host.post(path: "/ladder/sources", body: ["reminders": reminders, "events": events]) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                guard let data, let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = state["items"] as? [[String: Any]] else { return }
                self.host.entrusted.wakeAt = state["wake"] as? Double
                Task { @MainActor in _ = await self.host.entrusted.sync(items, revision: state["revision"] as? Double ?? 0, ask: false) }
            }
        }
    }
}
