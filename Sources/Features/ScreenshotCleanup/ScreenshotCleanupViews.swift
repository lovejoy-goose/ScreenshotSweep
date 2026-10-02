import Photos
import SwiftUI

/// Entry point of the Screenshot Cleanup feature. Photo access is requested here,
/// when the user opens the feature from the Dashboard — never at app launch.
struct ScreenshotCleanupView: View {
    @EnvironmentObject var store: SweepStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle("Скриншоты")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.backward")
                            Text("Главная")
                        }
                    }
                }
            }
            .onAppear { store.start() }
            .alert("Ошибка", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.errorMessage ?? "") }
            .alert("Готово", isPresented: Binding(
                get: { store.infoMessage != nil },
                set: { if !$0 { store.infoMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.infoMessage ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch store.access {
        case .unknown, .notDetermined:
            ProgressView("Запрашиваем доступ к фото…")
        case .denied:
            MessageView(
                icon: "lock",
                title: "Нет доступа к фото",
                text: "Разрешите доступ в Настройках → Katana Connector → Фото → «Все фото», чтобы увидеть скриншоты.",
                buttonTitle: "Открыть Настройки",
                action: store.openSettings
            )
        case .restricted:
            MessageView(
                icon: "hand.raised",
                title: "Доступ ограничен",
                text: "Доступ к фото запрещён ограничениями устройства (Экранное время или профиль управления).",
                buttonTitle: nil, action: nil
            )
        case .limited, .full:
            SweepView()
        }
    }
}

struct MessageView: View {
    let icon: String
    let title: String
    let text: String
    let buttonTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }
}

struct SweepView: View {
    @EnvironmentObject var store: SweepStore

    var body: some View {
        VStack(spacing: 12) {
            if store.access == .limited {
                LimitedBanner()
            }
            StatsBar()

            if store.isLoading && store.assets.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if store.assets.isEmpty {
                Spacer()
                MessageView(
                    icon: "photo.on.rectangle",
                    title: "Скриншотов нет",
                    text: store.access == .limited
                        ? "Среди выбранных фото нет скриншотов. Добавьте их в доступ или разрешите все фото."
                        : "В медиатеке не найдено ни одного скриншота.",
                    buttonTitle: nil, action: nil
                )
                Spacer()
            } else if let asset = store.current {
                SwipeCard(asset: asset)
                    .id(asset.localIdentifier)
                ActionButtons()
            } else {
                Spacer()
                MessageView(
                    icon: "checkmark.circle",
                    title: "Все скриншоты разобраны",
                    text: store.candidates.isEmpty
                        ? "Кандидатов на удаление нет."
                        : "Кандидатов на удаление: \(store.candidates.count). Проверьте и подтвердите.",
                    buttonTitle: store.candidates.isEmpty ? nil : "Проверить список",
                    action: { store.showReview = true }
                )
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { store.undo() } label: { Label("Отменить", systemImage: "arrow.uturn.backward") }
                    .disabled(!store.canUndo)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Проверить (\(store.candidates.count))") { store.showReview = true }
                    .disabled(store.candidates.isEmpty)
            }
        }
        .sheet(isPresented: $store.showReview) {
            ReviewView()
        }
    }
}

struct LimitedBanner: View {
    @EnvironmentObject var store: SweepStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Доступ только к выбранным фото").font(.subheadline.bold())
            Text("Видны только скриншоты, которые вы выбрали.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Выбрать ещё") { store.presentLimitedPicker() }
                Button("Разрешить все фото") { store.openSettings() }
            }
            .font(.caption.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatsBar: View {
    @EnvironmentObject var store: SweepStore

    var body: some View {
        HStack {
            Text("Обработано: \(store.processedCount) из \(store.assets.count)")
            Spacer()
            Text("На удаление: \(store.candidates.count)")
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct SwipeCard: View {
    @EnvironmentObject var store: SweepStore
    let asset: PHAsset
    @State private var offset: CGSize = .zero

    private let threshold: CGFloat = 110

    var body: some View {
        ZStack(alignment: .top) {
            AssetImage(asset: asset, targetSize: CGSize(width: 1200, height: 2400), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack {
                tag("ОСТАВИТЬ", .green).opacity(offset.width > 20 ? 1 : 0)
                Spacer()
                tag("УДАЛИТЬ", .red).opacity(offset.width < -20 ? 1 : 0)
            }
            .padding()

            if let date = asset.creationDate {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
        }
        .offset(x: offset.width)
        .rotationEffect(.degrees(Double(offset.width / 25)))
        .gesture(
            DragGesture()
                .onChanged { offset = $0.translation }
                .onEnded { value in
                    if value.translation.width > threshold {
                        store.decide(.keep)
                    } else if value.translation.width < -threshold {
                        store.decide(.delete)
                    }
                    withAnimation(.spring()) { offset = .zero }
                }
        )
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.headline).foregroundStyle(color)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
    }
}

struct ActionButtons: View {
    @EnvironmentObject var store: SweepStore

    var body: some View {
        HStack(spacing: 16) {
            Button {
                store.decide(.delete)
            } label: {
                Label("На удаление", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.red)

            Button {
                store.decide(.keep)
            } label: {
                Label("Оставить", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.green)
        }
        .controlSize(.large)
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: SweepStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        NavigationStack {
            Group {
                if store.candidates.isEmpty {
                    MessageView(icon: "tray", title: "Список пуст",
                                text: "Нет скриншотов, отмеченных на удаление.",
                                buttonTitle: nil, action: nil)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Обработано: \(store.processedCount). Кандидатов: \(store.candidates.count). Нажмите на скриншот, чтобы оставить его.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text("Точный освобождаемый размер не показывается: без загрузки оригиналов из iCloud его нельзя получить надёжно.")
                                .font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(store.candidates, id: \.localIdentifier) { asset in
                                    AssetImage(asset: asset, targetSize: CGSize(width: 300, height: 600), contentMode: .fill)
                                        .frame(height: 180)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .onTapGesture { store.toggleCandidate(asset) }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Проверка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Продолжить") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirming = true
                    } label: {
                        if store.isDeleting {
                            ProgressView()
                        } else {
                            Text("Удалить \(store.candidates.count) шт.").bold()
                        }
                    }
                    .disabled(store.candidates.isEmpty || store.isDeleting)
                }
            }
            .confirmationDialog(
                "Удалить \(store.candidates.count) скриншот(ов)?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) { store.deleteCandidates() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Они переместятся в «Недавно удалённые», откуда их можно восстановить в течение 30 дней.")
            }
        }
    }
}

struct AssetImage: View {
    @EnvironmentObject var store: SweepStore
    let asset: PHAsset
    let targetSize: CGSize
    let contentMode: ContentMode
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                VStack {
                    Image(systemName: "exclamationmark.icloud")
                    Text("Не удалось загрузить").font(.caption)
                }.foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: asset.localIdentifier) { load() }
    }

    private func load() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        store.imageManager.requestImage(for: asset, targetSize: targetSize,
                                        contentMode: contentMode == .fit ? .aspectFit : .aspectFill,
                                        options: options) { result, info in
            if let result {
                image = result
            } else if info?[PHImageErrorKey] != nil {
                failed = true
            }
        }
    }
}
