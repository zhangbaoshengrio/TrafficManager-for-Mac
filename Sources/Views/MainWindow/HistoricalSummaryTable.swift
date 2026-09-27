import SwiftUI

/// 选中聚合图上某根柱子后，用这张表代替实时的 `ProcessTableView`——
/// 数据来自 `DataStore.querySummary`（Phase 1），是那个时间窗里的历史汇总，
/// 不是实时速率，所以没有 Down now/Up now 两列（过去的速率没有意义）。
///
/// 每一列都可排序——用法照抄 `ProcessTableView`：`rawSummaries` 存查询原始
/// 结果，`summaries` 是排完序才拿去渲染的那份；`Table` 的 `sortOrder:`
/// 绑定只负责记录用户点了哪一列、升序还是降序，真正的排序还是得自己在
/// `summaries` 这个计算属性里做一遍，SwiftUI 不会替你重排数据源。
@MainActor
struct HistoricalSummaryTable: View {
    let since: TimeInterval
    let until: TimeInterval

    @State private var rawSummaries: [ProcessSummary] = []
    @State private var sortOrder: [KeyPathComparator<ProcessSummary>] = [
        KeyPathComparator(\ProcessSummary.totalBytes, order: .reverse)
    ]

    private var summaries: [ProcessSummary] { rawSummaries.sorted(using: sortOrder) }

    var body: some View {
        Group {
            if summaries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(L("detail.noData")).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(summaries, sortOrder: $sortOrder) {
                    TableColumn(L("column.process"), value: \.displayName) { s in
                        HStack(spacing: 6) {
                            ProcessIcon(iconPath: nil, bundleId: s.bundleId, fallbackSymbol: "app.fill")
                            Text(s.displayName).lineLimit(1)
                        }
                    }.width(min: 140)

                    TableColumn(L("column.download"), value: \.totalIn) { s in
                        Text(ByteFormatter.string(bytes: s.totalIn))
                            .foregroundColor(.blue).monospacedDigit()
                    }.width(min: 90)

                    TableColumn(L("column.upload"), value: \.totalOut) { s in
                        Text(ByteFormatter.string(bytes: s.totalOut))
                            .foregroundColor(.red).monospacedDigit()
                    }.width(min: 90)

                    TableColumn(L("column.total"), value: \.totalBytes) { s in
                        Text(ByteFormatter.string(bytes: s.totalBytes))
                            .fontWeight(.medium).monospacedDigit()
                    }.width(min: 100)
                }
            }
        }
        .task(id: since) {
            rawSummaries = (try? await DataStore.shared.querySummary(since: since, until: until)) ?? []
        }
    }
}
