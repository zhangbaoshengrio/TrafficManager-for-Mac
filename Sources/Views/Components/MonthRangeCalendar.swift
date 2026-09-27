import SwiftUI

/// 双月联动的日期范围选择器：左右各铺一整个月的网格，点第一下定起点，点第
/// 二下定终点（谁在前谁在后自动排好序），中间的日子整体高亮成一条带。
///
/// SwiftUI 没有这个控件（`DatePicker(.graphical)` 一次只管一个月、只能选
/// 单个日期），这里手写：网格布局交给 `MonthGridView` 负责单月渲染，这个
/// 类型只管两个月怎么并排、翻页箭头怎么翻、点击怎么落到 `start`/`end` 上。
struct MonthRangeCalendar: View {
    @Binding var start: Date
    @Binding var end: Date

    /// 左边那个月的月初——翻页只改这一个值，右边那个月永远是它的下一个月。
    @State private var anchorMonth: Date
    /// 两段式选择的中间状态：第一次点击落在这里，第二次点击才真正写回
    /// `start`/`end`（谁早谁晚自动排序）；`nil` 表示"上一次选择已经收尾，
    /// 下一次点击是全新的一次选择"。
    @State private var pendingAnchor: Date?

    init(start: Binding<Date>, end: Binding<Date>) {
        _start = start
        _end = end
        _anchorMonth = State(initialValue: Self.calendar.dateInterval(of: .month, for: start.wrappedValue)?.start
                             ?? start.wrappedValue)
    }

    private static var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 1 // 周日起始，跟参考设计一致
        return cal
    }

    private var secondMonth: Date {
        Self.calendar.date(byAdding: .month, value: 1, to: anchorMonth) ?? anchorMonth
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 20) {
                MonthGridView(monthAnchor: anchorMonth, rangeStart: start, rangeEnd: end, onSelectDay: select)
                MonthGridView(monthAnchor: secondMonth, rangeStart: start, rangeEnd: end, onSelectDay: select)
            }
        }
    }

    private func shift(_ deltaMonths: Int) {
        anchorMonth = Self.calendar.date(byAdding: .month, value: deltaMonths, to: anchorMonth) ?? anchorMonth
    }

    /// 两段式点击：第一下把 `start`/`end` 都暂定成同一天（马上就能看到那天
    /// 被圈出来，不用等第二下才有反馈）；第二下按早晚重新排好，结束这次
    /// 选择。跟大多数日期范围选择器的交互习惯一致。
    private func select(_ day: Date) {
        let day = Self.calendar.startOfDay(for: day)
        if let anchor = pendingAnchor {
            start = min(anchor, day)
            end = max(anchor, day)
            pendingAnchor = nil
        } else {
            start = day
            end = day
            pendingAnchor = day
        }
    }
}

/// 单个月份的网格：标题 + 星期表头 + 日期方格。不含任何"选中状态"的存储——
/// 纯按传入的 `rangeStart`/`rangeEnd` 计算每一格该长什么样，点击只是把
/// 点到的日期报给调用方，不自己决定这次点击的意义（那是 `MonthRangeCalendar`
/// 的两段式状态机的职责）。
private struct MonthGridView: View {
    let monthAnchor: Date
    let rangeStart: Date
    let rangeEnd: Date
    let onSelectDay: (Date) -> Void

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 1
        return cal
    }

    private var monthTitle: String {
        monthAnchor.formatted(.dateTime.month(.wide).year())
    }

    /// 网格里每一格对应的日期；月初前空出来的格子用 `nil` 占位，保证第一天
    /// 落在正确的星期列下面。
    private var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstOfMonth = interval.start
        let weekday = calendar.component(.weekday, from: firstOfMonth) // 1=周日...7=周六
        let leadingBlanks = weekday - 1
        let dayCount = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        var result: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for offset in 0..<dayCount {
            result.append(calendar.date(byAdding: .day, value: offset, to: firstOfMonth))
        }
        return result
    }

    private enum DayRole { case none, edge, inRange }

    private func role(for day: Date) -> DayRole {
        let d = calendar.startOfDay(for: day)
        let s = calendar.startOfDay(for: rangeStart)
        let e = calendar.startOfDay(for: rangeEnd)
        if d == s || d == e { return .edge }
        if d > s && d < e { return .inRange }
        return .none
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(monthTitle).font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach(calendar.veryShortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 24)
                    }
                }
            }
        }
        .frame(width: 210)
    }

    private func dayCell(_ day: Date) -> some View {
        let role = role(for: day)
        return Button {
            onSelectDay(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .background(role == .edge ? Color.accentColor : Color.clear)
                .foregroundStyle(role == .edge ? .white : .primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(role == .inRange ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }
}
