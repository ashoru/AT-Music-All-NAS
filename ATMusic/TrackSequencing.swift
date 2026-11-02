import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 盘号 / 音轨号的编排规则：单曲编辑器、批量编辑器与专辑页共用一套算法，
/// 保证「一键按序编号」的结果和专辑页显示顺序完全一致。
enum TrackSequencing {

    struct Assignment {
        let identityKey: String
        let disc: Int
        let track: Int
    }

    struct Plan {
        let assignments: [Assignment]
        let discCount: Int
        let summary: String

        func assignment(for identityKey: String) -> Assignment? {
            assignments.first { $0.identityKey == identityKey }
        }
    }

    /// 按当前列表顺序连续编号：
    /// - 盘号：有「统一盘号」覆盖值时全部用覆盖值，否则保留每首原有盘号；
    /// - 同一盘内按「显示顺序」从 startTrack 连续编号，`order` 传入拖动后的自定义顺序时以它为准。
    /// 多盘专辑因此会得到「每盘各自 01…N」的正确结果，而不是整张连续数下去。
    static func plan(songs: [Song], order: [String]? = nil, discOverride: Int?, startTrack: Int = 1) -> Plan {
        let start = max(1, startTrack)
        var discOrder: [Int] = []
        var buckets: [Int: [Song]] = [:]
        for song in Self.sorted(songs: songs, order: order) {
            let disc = discOverride ?? max(1, song.discNumber)
            if buckets[disc] == nil {
                buckets[disc] = []
                discOrder.append(disc)
            }
            buckets[disc]?.append(song)
        }

        var assignments: [Assignment] = []
        var lines: [String] = []
        for disc in discOrder.sorted() {
            let group = buckets[disc] ?? []
            guard !group.isEmpty else { continue }
            for (index, song) in group.enumerated() {
                assignments.append(Assignment(identityKey: song.identityKey, disc: disc, track: start + index))
            }
            let first = start
            let last = start + group.count - 1
            if group.count > 1 {
                lines.append("第 \(disc) 盘 · 音轨 \(two(first))–\(two(last))")
            } else {
                lines.append("第 \(disc) 盘 · 音轨 \(two(first))")
            }
        }
        return Plan(
            assignments: assignments,
            discCount: discOrder.count,
            summary: lines.isEmpty ? "暂无可编号的曲目" : lines.joined(separator: "；")
        )
    }

    /// 依「自定义顺序」重排：order 里没有的歌曲按原数组顺序补到末尾，
    /// 保证拖动排序后不会丢歌、也不会重复。
    static func sorted(songs: [Song], order: [String]?) -> [Song] {
        guard let order, !order.isEmpty else { return songs }
        let byKey = Dictionary(songs.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var ordered: [Song] = []
        ordered.reserveCapacity(songs.count)
        for key in order {
            if let song = byKey[key], seen.insert(key).inserted { ordered.append(song) }
        }
        for song in songs where seen.insert(song.identityKey).inserted { ordered.append(song) }
        return ordered
    }

    /// 数字输入框统一解析：非法/空返回 nil，越界自动夹紧。
    static func parseNumber(_ text: String, range: ClosedRange<Int> = 1...999) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed) else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func two(_ value: Int) -> String {
        String(format: "%02d", max(0, value))
    }

    /// 展示用："第 2 盘 · 音轨 07"
    static func label(disc: Int, track: Int) -> String {
        "第 \(max(1, disc)) 盘 · 音轨 \(two(max(0, track)))"
    }
}


/// 批量编辑器里「逐曲微调」的单曲编号（字符串承载，空串 = 该曲不写该标签）。
struct TrackNumberingOverride: Equatable {
    var track: String
    var disc: String
}

// MARK: - 批量编辑器共用的「曲目编号」卡片

/// NAS 与本地两套批量编辑器共用同一张卡片：起始音轨号 + 统一盘号 + 一键按序编号，
/// 再展开「逐曲微调」逐首改盘号/音轨号——自动与手改两不误，两边行为完全一致。
struct TrackNumberingCard: View {
    let songs: [Song]
    /// 拖动排序后的自定义顺序（identityKey 列表）；空数组 = 按传入顺序。
    @Binding var order: [String]
    @Binding var startTrack: String
    @Binding var discOverride: String
    @Binding var sequentialEnabled: Bool
    @Binding var overrides: [String: TrackNumberingOverride]

    @State private var showPerSong = false
    @State private var draggingKey: String?

    private var discOverrideNumber: Int? {
        TrackSequencing.parseNumber(discOverride, range: 1...999)
    }

    private var plan: TrackSequencing.Plan {
        TrackSequencing.plan(
            songs: songs,
            order: order,
            discOverride: discOverrideNumber,
            startTrack: TrackSequencing.parseNumber(startTrack, range: 1...999) ?? 1
        )
    }

    /// 当前显示顺序（拖动排序后的结果）
    private var orderedSongs: [Song] {
        TrackSequencing.sorted(songs: songs, order: order)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            inputs
            applyButton
            if sequentialEnabled || !overrides.isEmpty {
                summary
                perSongSection
            }
            footerHint
        }
        .onAppear {
            if order.isEmpty { order = songs.map(\.identityKey) }
        }
        .onChange(of: songs.map(\.identityKey)) { keys in
            // 选曲变化（改勾选、换歌单）时，把顺序与逐曲手改同步到新选区
            let valid = Set(keys)
            var next = order.filter { valid.contains($0) }
            for key in keys where !next.contains(key) { next.append(key) }
            order = next
            for key in Array(overrides.keys) where !valid.contains(key) {
                overrides.removeValue(forKey: key)
            }
        }
    }

    // MARK: 子视图

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "number.square")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
            Text("曲目编号")
                .font(ATMusicFont.appFont(13, .semibold))
                .foregroundStyle(Color.atmusicComment)
            Spacer()
            if !overrides.isEmpty {
                Text("已排 \(overrides.count) 首")
                    .font(ATMusicFont.appFont(11, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
            }
        }
    }

    private var inputs: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("起始音轨号")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                    .frame(width: 80, alignment: .leading)
                TextField("1", text: numericBinding($startTrack))
                    .font(ATMusicFont.appFont(14))
                    .keyboardType(.numberPad)
                Spacer(minLength: 0)
            }
            Divider().overlay(Color.atmusicComment.opacity(0.12))
            HStack(spacing: 12) {
                Text("统一盘号")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                    .frame(width: 80, alignment: .leading)
                TextField("留空保持原样", text: numericBinding($discOverride))
                    .font(ATMusicFont.appFont(14))
                    .keyboardType(.numberPad)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var applyButton: some View {
        HStack(spacing: 8) {
            Button {
                ATMusicHaptics.select()
                withAnimation(.snappy(duration: 0.2)) {
                    if sequentialEnabled && !overrides.isEmpty {
                        regenerate()
                    } else {
                        sequentialEnabled = true
                        if TrackSequencing.parseNumber(startTrack, range: 1...999) == nil {
                            startTrack = "1"
                        }
                        regenerate()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: sequentialEnabled ? "arrow.triangle.2.circlepath" : "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                    Text(sequentialEnabled ? (overrides.isEmpty ? "按序编号" : "重新按序编号") : "一键按序编号")
                        .font(ATMusicFont.appFont(13, .semibold))
                    Spacer()
                }
                .foregroundStyle(Color.atmusicAmber)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.atmusicAmber.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            if !overrides.isEmpty {
                Button {
                    ATMusicHaptics.tap()
                    withAnimation(.snappy(duration: 0.2)) {
                        overrides = [:]
                        sequentialEnabled = false
                    }
                } label: {
                    Text("清除")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.summary)
                .font(ATMusicFont.appFont(11, .medium))
                .foregroundStyle(Color.atmusicAmber.opacity(0.95))
            Text("保存时按上面「逐曲微调」里的实际值写入；未展开微调的歌曲即按此摘要执行。")
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment.opacity(0.8))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var perSongSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                ATMusicHaptics.tap()
                withAnimation(.snappy(duration: 0.2)) { showPerSong.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showPerSong ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("逐曲微调（\(songs.count) 首）")
                        .font(ATMusicFont.appFont(12, .semibold))
                    Spacer()
                }
                .foregroundStyle(Color.atmusicComment)
            }
            .buttonStyle(.plain)

            if showPerSong {
                VStack(alignment: .leading, spacing: 6) {
                    Text("按住右侧把手拖动即可重排，松手即按新顺序重新编号（逐格手改会被覆盖，建议最后再改）")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment.opacity(0.8))
                    LazyVStack(spacing: 6) {
                        ForEach(Array(orderedSongs.enumerated()), id: \.element.identityKey) { index, song in
                            perSongRow(song, position: index)
                                .onDrag {
                                    draggingKey = song.identityKey
                                    ATMusicHaptics.tap()
                                    return NSItemProvider(object: song.identityKey as NSString)
                                }
                                .onDrop(
                                    of: [.text],
                                    delegate: TrackRowDropDelegate(
                                        itemKey: song.identityKey,
                                        order: $order,
                                        draggingKey: $draggingKey,
                                        onReorder: renumberAfterReorder
                                    )
                                )
                        }
                    }
                }
                .padding(10)
                .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func perSongRow(_ song: Song, position: Int) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", position + 1))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.atmusicComment.opacity(0.7))
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.name)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text(song.artists.isEmpty ? "未知艺术家" : song.artists)
                    .font(ATMusicFont.appFont(10))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            compactField(title: "盘", text: overrideBinding(song.identityKey, \.disc))
            compactField(title: "轨", text: overrideBinding(song.identityKey, \.track))
            VStack(spacing: 2) {
                moveButton(song.identityKey, up: true)
                moveButton(song.identityKey, up: false)
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atmusicComment.opacity(0.55))
                .frame(width: 16)
        }
        .contentShape(Rectangle())
    }

    private func moveButton(_ key: String, up: Bool) -> some View {
        Button {
            ATMusicHaptics.select()
            withAnimation(.snappy(duration: 0.18)) {
                move(key, up: up)
            }
            renumberAfterReorder()
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.atmusicComment)
                .frame(width: 18, height: 13)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isFirstOrLast(key, up: up))
        .opacity(isFirstOrLast(key, up: up) ? 0.35 : 1)
    }

    private func compactField(title: String, text: Binding<String>) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment)
            TextField("–", text: numericBinding(text))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .frame(width: 34)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var footerHint: some View {
        Text(overrides.isEmpty
             ? "按界面当前顺序连续编号；多盘专辑自动按盘分组，每盘各自从起始号开始。"
             : "已生成逐曲编号，可在上方逐首改；清空某一格表示该曲不写该标签。")
            .font(ATMusicFont.appFont(11))
            .foregroundStyle(Color.atmusicComment.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 逻辑

    /// 保证 order 是完整的歌曲序列（拖动/上下移都在这个数组上做）。
    private func normalizedOrder() -> [String] {
        var keys = order
        for song in songs where !keys.contains(song.identityKey) {
            keys.append(song.identityKey)
        }
        return keys
    }

    private func move(_ key: String, up: Bool) {
        var keys = normalizedOrder()
        guard let index = keys.firstIndex(of: key) else { return }
        let target = up ? index - 1 : index + 1
        guard keys.indices.contains(target) else { return }
        keys.swapAt(index, target)
        order = keys
    }

    private func isFirstOrLast(_ key: String, up: Bool) -> Bool {
        let keys = normalizedOrder()
        guard let index = keys.firstIndex(of: key) else { return true }
        return up ? index == 0 : index == keys.count - 1
    }

    /// 拖动/上下移之后：按新顺序重排编号（逐格手改会被新顺序覆盖，界面上有明确提示）。
    private func renumberAfterReorder() {
        sequentialEnabled = true
        if TrackSequencing.parseNumber(startTrack, range: 1...999) == nil { startTrack = "1" }
        regenerate()
    }

    /// 用当前计划重新填满逐曲编号（覆盖用户手改，所以要用户主动点）。
    private func regenerate() {
        let fresh = plan
        var next: [String: TrackNumberingOverride] = [:]
        for assignment in fresh.assignments {
            next[assignment.identityKey] = TrackNumberingOverride(
                track: String(assignment.track),
                disc: String(assignment.disc)
            )
        }
        overrides = next
    }

    private func overrideBinding(_ key: String, _ path: WritableKeyPath<TrackNumberingOverride, String>) -> Binding<String> {
        Binding(
            get: { overrides[key]?[keyPath: path] ?? "" },
            set: { newValue in
                var entry = overrides[key] ?? TrackNumberingOverride(track: "", disc: "")
                entry[keyPath: path] = newValue
                overrides[key] = entry
            }
        )
    }

    private func numericBinding(_ source: Binding<String>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue },
            set: { newValue in
                source.wrappedValue = String(newValue.filter { $0.isNumber }.prefix(3))
            }
        )
    }
}

/// 逐曲列表的拖动重排代理：拖到哪一行就把被拖的歌曲挪到那一行的位置，
/// 并在拖动过程中实时触发重新编号，用户松手前就能看到 01/02 的联动。
struct TrackRowDropDelegate: DropDelegate {
    let itemKey: String
    @Binding var order: [String]
    @Binding var draggingKey: String?
    let onReorder: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingKey, draggingKey != itemKey else { return }
        var keys = order
        guard let from = keys.firstIndex(of: draggingKey),
              let to = keys.firstIndex(of: itemKey) else { return }
        withAnimation(.snappy(duration: 0.16)) {
            keys.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        order = keys
        onReorder()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingKey = nil
        ATMusicHaptics.success()
        return true
    }
}
