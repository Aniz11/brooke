import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @EnvironmentObject private var media: MediaStore
    @Environment(\.dismiss) private var dismiss

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var videoItems: [PhotosPickerItem] = []
    @State private var showTrackImporter = false
    @State private var errorText: String?
    @State private var confirmReset = false
    @StateObject private var preview = TrackPreview()

    private let photoColumns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                alarmSection
                musicSection
                photosSection
                videosSection
                modeSection
                testSection
                statsSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .overlay {
                if media.isImporting {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text("Сохраняю…").foregroundStyle(Theme.text)
                        }
                        .padding(28)
                        .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
                    }
                }
            }
            .fileImporter(isPresented: $showTrackImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    preview.stop()
                    Task {
                        do {
                            try await media.importTrack(from: url)
                        } catch {
                            errorText = "Не получилось открыть этот файл. Попробуй другой mp3."
                        }
                    }
                case .failure:
                    errorText = "Не получилось открыть файл."
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    await media.importPhotos(items)
                    photoItems = []
                }
            }
            .onChange(of: videoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    await media.importVideos(items)
                    videoItems = []
                }
            }
            .alert("Ошибка", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .confirmationDialog("Сбросить серию и рекорд?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) { engine.clearStats() }
            }
            .onDisappear { preview.stop() }
        }
    }

    // MARK: Alarm

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: engine.hour, minute: engine.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                engine.setTime(hour: parts.hour ?? 6, minute: parts.minute ?? 0)
            }
        )
    }

    private var alarmSection: some View {
        Section {
            DatePicker("Время", selection: timeBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .environment(\.locale, Locale(identifier: "ru_RU"))
            Toggle("Будильник включён", isOn: $engine.enabled)
        } header: {
            Text("Будильник · каждый день")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Music

    private var musicSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.trackName ?? "Трек не выбран")
                        .lineLimit(1)
                    Text(media.trackURL == nil ? "Пока звучит стандартный сигнал" : "Громкость нарастает за 20 секунд")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                if let url = media.trackURL {
                    Button {
                        preview.toggle(url)
                    } label: {
                        Image(systemName: preview.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                showTrackImporter = true
            } label: {
                Label(media.trackURL == nil ? "Выбрать трек (mp3)" : "Заменить трек", systemImage: "folder")
            }
        } header: {
            Text("Музыка")
        } footer: {
            Text("Сначала сохрани mp3 в приложение «Файлы» (например, из Telegram: «Сохранить в Файлы»).")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Photos

    private var photosSection: some View {
        Section {
            if !media.photos.isEmpty {
                LazyVGrid(columns: photoColumns, spacing: 8) {
                    ForEach(media.photos, id: \.self) { url in
                        PhotoThumb(url: url) { media.deletePhoto(url) }
                    }
                }
                .padding(.vertical, 6)
            }
            PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .images) {
                Label("Добавить фото из галереи", systemImage: "plus")
            }
        } header: {
            Text("Фото · \(media.photos.count)")
        } footer: {
            Text("Показываются слайд-шоу, пока звонит будильник. Нажми ✕, чтобы удалить.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Videos

    private var videosSection: some View {
        Section {
            ForEach(media.videos, id: \.self) { url in
                VideoRow(url: url)
                    .swipeActions {
                        Button(role: .destructive) {
                            media.deleteVideo(url)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
            }
            PhotosPicker(selection: $videoItems, maxSelectionCount: 10, matching: .videos) {
                Label("Добавить видео из галереи", systemImage: "plus")
            }
        } header: {
            Text("Видео · \(media.videos.count)")
        } footer: {
            Text("После того как решишь пример, включится одно случайное видео. Пропустить его нельзя. Смахни влево, чтобы удалить.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Mode

    private var modeSection: some View {
        Section {
            if engine.usesAlarmKit {
                Label {
                    Text("AlarmKit — звонит как системный будильник, даже если Brooke закрыт.")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                }
            } else {
                Label {
                    Text("Фоновый режим: на ночь сверни Brooke, но не смахивай его из списка приложений. Если iOS всё же закроет его, придут запасные уведомления с твоим треком.")
                } icon: {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.accent)
                }
                if AlarmKitBridge.isSupported {
                    Button("Включить AlarmKit") {
                        Task {
                            _ = await AlarmKitBridge.requestAuthorization()
                            engine.refresh()
                        }
                    }
                } else {
                    Text("iOS \(UIDevice.current.systemVersion). После обновления до iOS 26 или новее Brooke сам перейдёт на AlarmKit.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
        } header: {
            Text("Как работает будильник")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Test

    private var testSection: some View {
        Section {
            Button {
                engine.startTest()
                dismiss()
            } label: {
                Label("Проверить: зазвонит через 10 секунд", systemImage: "play.circle")
            }
        } footer: {
            Text("После нажатия можно заблокировать экран. Проверка не влияет на серию.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Stats

    private var statsSection: some View {
        Section {
            HStack {
                Text("Серия")
                Spacer()
                Text("\(engine.streak) \(Format.days(engine.streak))").foregroundStyle(Theme.muted)
            }
            HStack {
                Text("Рекорд")
                Spacer()
                Text("\(engine.bestStreak) \(Format.days(engine.bestStreak))").foregroundStyle(Theme.muted)
            }
            Button("Сбросить статистику", role: .destructive) { confirmReset = true }
        } header: {
            Text("Статистика")
        } footer: {
            Text("День засчитывается, если пример решён в течение 15 минут после звонка.")
        }
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Rows

struct PhotoThumb: View {
    let url: URL
    let onDelete: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Theme.surface
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.borderless)
                .padding(5)
                .accessibilityLabel("Удалить фото")
            }
            .task(id: url) { image = await ImageLoader.load(url, maxPixel: 300) }
    }
}

struct VideoRow: View {
    let url: URL
    @State private var thumbnail: UIImage?
    @State private var duration: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 56, height: 56)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Theme.surface
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.9))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Видео")
                Text(duration > 0 ? Format.duration(duration) : "…")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .task(id: url) {
            let result = await ImageLoader.videoThumbnail(url)
            thumbnail = result.0
            duration = result.1
        }
    }
}

/// Plays the chosen track in Settings so the person can check it.
@MainActor
final class TrackPreview: ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if isPlaying {
            stop()
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        isPlaying = player?.isPlaying ?? false
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
