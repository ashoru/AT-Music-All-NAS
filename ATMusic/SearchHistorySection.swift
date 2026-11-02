import SwiftUI

// MARK: - 搜索历史（顶部胶囊列表）
struct SearchHistorySection: View {
    @ObservedObject var store = SearchHistoryStore.shared
    let onSelect: (String) -> Void

    var body: some View {
        if store.history.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("历史搜索")
                        .font(ATMusicFont.appFont(15, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Button {
                        ATMusicHaptics.tap()
                        store.clear()
                        ToastCenter.shared.show("已清空搜索历史")
                    } label: {
                        Label("清空", systemImage: "trash")
                            .font(ATMusicFont.appFont(12, .medium))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .buttonStyle(.plain)
                }
                if #available(iOS 16, *) {
                    FlowLayout(spacing: 8) {
                        ForEach(store.history, id: \.self) { word in
                            historyChip(word)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(store.history, id: \.self) { word in
                            historyChip(word)
                        }
                    }
                }
            }
        }
    }

    private func historyChip(_ word: String) -> some View {
        HStack(spacing: 6) {
            Button {
                ATMusicHaptics.tap()
                onSelect(word)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .medium))
                    Text(word)
                        .font(ATMusicFont.appFont(13, .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.atmusicLabel)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    ATMusicGlass(shape: Capsule())
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button {
                ATMusicHaptics.tap()
                store.remove(word)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.atmusicComment.opacity(0.8))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.atmusicGlassFill))
            }
            .buttonStyle(.plain)
        }
    }
}
