import SwiftUI

/// Swipe between trip days. A chip strip on top shows every day and jumps on tap; each page is a
/// header card plus a vertical timeline. Opens on today's page while the trip is happening.
@MainActor
struct DayPager: View {
    let guide: TripGuide
    /// Last viewed day, remembered across launches.
    @AppStorage("guide.day") private var selection = 0
    /// The trip day it was when the itinerary was last opened (-1 = before/after the trip).
    @AppStorage("guide.todaySeen") private var todaySeen = -1

    /// Day pages start on the trip's first day (Nov 26, 2026) in Puerto Rico time.
    static let firstDay: DateComponents = DateComponents(year: 2026, month: 11, day: 26)
    static let timeZone = TimeZone(identifier: "America/Puerto_Rico") ?? .current

    private var todayIndex: Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        guard let start = calendar.date(from: Self.firstDay),
              let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: Date())).day,
              guide.days.indices.contains(offset) else { return nil }
        return offset
    }

    var body: some View {
        VStack(spacing: 0) {
            chips
            TabView(selection: $selection) {
                ForEach(Array(guide.days.enumerated()), id: \.offset) { index, day in
                    DayPage(day: day, dayNumber: index + 1, dayCount: guide.days.count, isToday: index == todayIndex)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: selection)
        }
        .onAppear {
            // Keep the remembered day, except when a new trip day has started since last time: then jump to today.
            let today = todayIndex ?? -1
            if today >= 0 && today != todaySeen { selection = today }
            todaySeen = today
            if !guide.days.indices.contains(selection) { selection = 0 }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(guide.days.enumerated()), id: \.offset) { index, day in
                        let parts = day.date.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        let selected = index == selection
                        Button { selection = index } label: {
                            VStack(spacing: 2) {
                                Text(parts.first ?? "").font(.caption2.weight(.semibold)).textCase(.uppercase)
                                Text(parts.last?.split(separator: " ").last.map(String.init) ?? "").font(.title3.bold().monospacedDigit())
                                Circle().fill(index == todayIndex ? (selected ? Color.onBrand : Color.brand) : .clear).frame(width: 5, height: 5)
                            }
                            .frame(width: 52, height: 64)
                            .foregroundStyle(selected ? Color.onBrand : Color.primary)
                            .background(selected ? Color.brand : Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel(Text("\(day.date), \(day.title)\(index == todayIndex ? ", today" : "")"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .onChange(of: selection) { _, index in withAnimation { proxy.scrollTo(index, anchor: .center) } }
        }
    }
}

@MainActor
struct DayPage: View {
    let day: TripGuide.Day
    let dayNumber: Int
    let dayCount: Int
    let isToday: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(day.stops.enumerated()), id: \.element.id) { index, stop in
                        TimelineRow(stop: stop, isFirst: index == 0, isLast: index == day.stops.count - 1)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(dayNumber < dayCount ? "Swipe for day \(dayNumber + 1) →" : "That’s the trip 🇵🇷")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DAY \(dayNumber) OF \(dayCount)").font(.caption.weight(.bold)).foregroundStyle(Color.onBrand.opacity(0.8))
                Spacer()
                if isToday {
                    Text("TODAY").font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.onBrand.opacity(0.2), in: Capsule())
                }
            }
            Text(day.title).font(.title2.bold())
            Text(day.date).font(.subheadline).opacity(0.85)
            Label(day.transport, systemImage: day.transport.localizedCaseInsensitiveContains("boat") ? "ferry.fill"
                  : day.transport.localizedCaseInsensitiveContains("car") || day.transport.localizedCaseInsensitiveContains("uber") ? "car.fill"
                  : "figure.walk")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.onBrand.opacity(0.18), in: Capsule())
        }
        .foregroundStyle(Color.onBrand)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.brand, Color.brand.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct TimelineRow: View {
    let stop: TripGuide.Stop
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(stop.time)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 12)
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : Color.brand.opacity(0.3)).frame(width: 2, height: 14)
                Circle().fill(Color.brand).frame(width: 10, height: 10)
                Rectangle().fill(isLast ? Color.clear : Color.brand.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(stop.title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                ForEach(stop.notes, id: \.self) { note in
                    Text(note).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
