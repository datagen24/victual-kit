import SwiftUI
import VictualCore
import VictualHealth

/// Estimated reorder dates for prescriptions, and the notices the server raised.
///
/// Prescription names appear here and nowhere else: never in a notification, a log
/// or a file. The content is blurred whenever the app is not in front, so the
/// app-switcher snapshot shows no names.
struct RefillsScreen: View {
    let store: RefillStore

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            statusSection
            if store.accessLost {
                Section {
                    Label("The server no longer lets this key read refills. Nothing is kept on this phone.", systemImage: "lock.fill")
                }
            }
            noticesSection
            itemsSection
            Section {
                Text("Dates are estimates from recorded fills. They do not say a pharmacy or insurer will allow a refill.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Refills")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .privacySensitive()
        .blur(radius: scenePhase == .active ? 0 : 24)
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if let error = store.state.error {
                Label(error.errorDescription ?? "The last refresh failed.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            } else if let last = store.lastRefreshed {
                Text("Updated \(last.formatted(.relative(presentation: .named)))")
            }
            if store.notificationsAllowed != true {
                Button("Allow refill reminders") { Task { await store.requestNotificationPermission() } }
            }
        } header: {
            Text("Today is \(store.today.description)")
        } footer: {
            Text("This phone's date is sent with each refresh. A reminder says only that a refill is coming up or due; open the app for the rest.")
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var noticesSection: some View {
        if !store.notices.isEmpty {
            Section("Notices") {
                ForEach(store.notices) { notice in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.recipeName.isEmpty ? "A prescription" : notice.recipeName).font(.headline)
                        Text(noticeText(notice))
                        Text(notice.source.provenance).font(.caption).foregroundStyle(.secondary)
                        Button("Acknowledge") { Task { await store.acknowledge(noticeKey: notice.key) } }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func noticeText(_ notice: RefillNotice) -> String {
        switch notice.kind {
        case .approaching: "Estimated reorder date \(notice.reorderDate.description) is coming up."
        case .due:
            if let overdue = notice.daysOverdue, overdue > 0 {
                "Estimated reorder date \(notice.reorderDate.description) was \(overdue) day\(overdue == 1 ? "" : "s") ago."
            } else {
                "Estimated reorder date \(notice.reorderDate.description) is today."
            }
        }
    }

    // MARK: Prescriptions

    private var itemsSection: some View {
        Section("Prescriptions") {
            if store.items.isEmpty {
                Text("No refill information.").foregroundStyle(.secondary)
            }
            ForEach(store.items) { item in
                NavigationLink {
                    RefillDetailScreen(store: store, item: item)
                } label: {
                    RefillRow(item: item)
                }
            }
        }
    }
}

private struct RefillRow: View {
    let item: RefillItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.recipeName.isEmpty ? "A prescription" : item.recipeName)
                Spacer()
                StatusBadge(status: item.status)
            }
            if let countdown = item.countdown { Text(countdown).font(.subheadline) }
            if let date = item.reorderDate, let source = item.source {
                Text("\(date.description) · \(source.provenance)").font(.caption).foregroundStyle(.secondary)
            }
            if let reason = item.unknownReason {
                Text(reason.explanation).font(.caption).foregroundStyle(.secondary)
            }
            if let from = item.correctedFrom {
                Label("Date changed from \(from.description) after a correction", systemImage: "pencil")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let order = item.openOrder {
                Text("Ordered \(order.orderedOn.description) (\(order.ageDays) day\(order.ageDays == 1 ? "" : "s") ago)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.asOfSource == .serverUTC {
                Label("The server's date was used, not this phone's.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct StatusBadge: View {
    let status: RefillStatus

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .ok: "OK"
        case .approaching: "Approaching"
        case .due: "Due"
        case .ordered: "Ordered"
        case .unknown: "Unknown"
        }
    }

    private var color: Color {
        switch status {
        case .ok: .green
        case .approaching: .orange
        case .due: .red
        case .ordered: .blue
        case .unknown: .gray
        }
    }
}

/// One prescription's fills, voided ones included.
private struct RefillDetailScreen: View {
    let store: RefillStore
    let item: RefillItem

    @State private var fills: [RefillFillRecord] = []

    var body: some View {
        List {
            Section {
                RefillRow(item: item)
            }
            Section("Fills") {
                ForEach(fills) { fill in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(fill.filledOn.description)
                            Text(fill.suppliedDays.map { "\($0) days supplied" } ?? "Days supplied not recorded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fill.isVoided { Text("Corrected").font(.caption).foregroundStyle(.secondary) }
                        else if fill.isCurrent { Text("Current").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Refill")
        .navigationBarTitleDisplayMode(.inline)
        .task { fills = await store.fills(recipeID: item.recipeID) }
        .privacySensitive()
    }
}
