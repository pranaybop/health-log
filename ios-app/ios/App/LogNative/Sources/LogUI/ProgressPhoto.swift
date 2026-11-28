import SwiftUI
import UIKit
import PhotosUI
import LogCore

// Optional progress photo after a weigh-in, and the timeline on Trends → Weight.
// Images are resized to a JPEG before upload. The bytes go to a private bucket
// through a signed URL; this screen only ever holds that short-lived URL.

struct WeighOffer: Equatable {
    var weightLb: Double
    var weightId: String?
    var takenAt: String
}

enum MLJSON {
    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}

enum ProgressJPEG {
    /// Longest edge 1600px, JPEG, kept under the bucket’s 2 MB limit.
    static func data(from image: UIImage) -> Data? {
        let drawn = redraw(image, maxEdge: 1600)
        var quality: CGFloat = 0.72
        var data = drawn.jpegData(compressionQuality: quality)
        while let current = data, current.count > 1_800_000, quality > 0.45 {
            quality -= 0.08
            data = drawn.jpegData(compressionQuality: quality)
        }
        if let current = data, current.count > 2_097_152 { return nil }
        return data
    }

    private static func redraw(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxEdge && longest > 0 ? maxEdge / longest : 1
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: target)).fill()
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

struct WeighPhotoOffer: View {
    var offer: WeighOffer
    var onDismiss: () -> Void
    var onSaved: () -> Void
    @Environment(LogStore.self) private var store
    @State private var libraryItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MLHairline()
            Text("Add a progress photo")
                .font(.subheadline)
                .foregroundStyle(LogColor.ink2)
                .accessibilityIdentifier("weigh.photo")
            HStack(spacing: 10) {
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        note = "The camera isn’t available on this device."
                    }
                } label: {
                    Label("Camera", systemImage: "camera").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(LogColor.accent)
                .accessibilityIdentifier("weigh.camera")
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Label("Library", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(LogColor.accent)
                .accessibilityIdentifier("weigh.library")
            }
            .disabled(busy)
            HStack {
                Button("Not now", action: onDismiss)
                    .font(.subheadline)
                    .foregroundStyle(LogColor.ink2)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("weigh.photo.dismiss")
                Spacer()
                if busy { ProgressView() }
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(LogColor.critInk)
                    .accessibilityIdentifier("weigh.photo.note")
            }
        }
        .padding(.top, 4)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                defer { libraryItem = nil }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await save(image)
                } else {
                    note = "Couldn’t read that photo."
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                Task { await save(image) }
            } onCancel: {
                showCamera = false
            }
            .ignoresSafeArea()
        }
    }

    private func save(_ image: UIImage) async {
        guard !busy else { return }
        guard let jpeg = ProgressJPEG.data(from: image) else {
            note = "That photo is too large."
            return
        }
        busy = true
        note = nil
        do {
            try await store.uploadProgressPhoto(jpeg: jpeg, weightLb: offer.weightLb, weightId: offer.weightId, takenAt: offer.takenAt)
            onSaved()
        } catch let e as LogError {
            note = e == .unauthorized
                ? "Passcode was rejected. Lock and unlock again."
                : "Could not save the photo: \(e.message)"
        } catch {
            note = "Could not save the photo."
        }
        busy = false
    }
}

struct ProgressPhotosCard: View {
    var photos: [ProgressPhoto]
    @Environment(LogStore.self) private var store
    @State private var viewer: ProgressPhoto?
    @State private var pendingDelete: ProgressPhoto?
    @State private var note: String?

    private var sorted: [ProgressPhoto] {
        photos.sorted { lhs, rhs in
            (lhs.takenAt ?? lhs.day ?? "") > (rhs.takenAt ?? rhs.day ?? "")
        }
    }

    var body: some View {
        LogCard("Progress photos") {
            if sorted.isEmpty {
                EmptyNote("After a weigh-in you can add a private photo. It shows up here with the date and weight.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(sorted, id: \.stableID) { photo in
                            tile(photo)
                        }
                    }
                }
            }
            if let note { Caption(note) }
        }
        .confirmationDialog("Delete this photo?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete photo", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes it from your log.")
        }
        .sheet(item: $viewer) { photo in
            PhotoViewer(photo: photo) { Task { await delete(photo) } }
        }
    }

    private func tile(_ photo: ProgressPhoto) -> some View {
        let cap = PhotoCaption.of(photo)
        return VStack(alignment: .leading, spacing: 8) {
            Button { viewer = photo } label: {
                PhotoThumb(photo: photo)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Progress photo, \(cap.date)\(cap.weight.isEmpty ? "" : ", \(cap.weight)")")
            HStack {
                Text(cap.date).font(.caption).foregroundStyle(LogColor.ink2)
                Spacer(minLength: 6)
                if !cap.weight.isEmpty {
                    Text(cap.weight).font(.caption.weight(.semibold)).foregroundStyle(LogColor.ink)
                }
            }
            if photo.id != nil {
                Button("Delete") { pendingDelete = photo }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LogColor.critInk)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete photo from \(cap.date)")
            }
        }
        .frame(width: 168, alignment: .leading)
    }

    private func confirmDelete() {
        guard let photo = pendingDelete else { return }
        pendingDelete = nil
        Task { await delete(photo) }
    }

    private func delete(_ photo: ProgressPhoto) async {
        guard let id = photo.id else { return }
        if viewer?.stableID == photo.stableID { viewer = nil }
        do {
            try await store.deleteProgressPhoto(id: id)
            note = nil
        } catch {
            note = "Couldn’t delete the photo."
        }
    }
}

private struct PhotoCaption {
    var date: String
    var weight: String

    static func of(_ photo: ProgressPhoto) -> PhotoCaption {
        let date: String
        if let day = photo.day, !day.isEmpty {
            date = LogTime.shortDate(key: day)
        } else if let at = photo.takenDate {
            date = LogTime.shortDate(at)
        } else {
            date = "—"
        }
        let weight = photo.weightLb.map { "\(Fmt.num($0, 1)) lb" } ?? ""
        return PhotoCaption(date: date, weight: weight)
    }
}

private struct PhotoThumb: View {
    var photo: ProgressPhoto

    var body: some View {
        PhotoImage(photo: photo, fit: false)
            .frame(width: 168, height: 224)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PhotoImage: View {
    var photo: ProgressPhoto
    var fit: Bool

    var body: some View {
        let url = photo.url.flatMap(URL.init(string:))
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            default:
                ZStack {
                    LogColor.surface2
                    Image(systemName: "photo").font(.title2).foregroundStyle(LogColor.ink2)
                }
            }
        }
    }
}

private struct PhotoViewer: View {
    var photo: ProgressPhoto
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false

    var body: some View {
        let cap = PhotoCaption.of(photo)
        NavigationStack {
            VStack(spacing: 16) {
                PhotoImage(photo: photo, fit: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack {
                    Text(cap.date).foregroundStyle(LogColor.ink2)
                    Spacer()
                    if !cap.weight.isEmpty {
                        Text(cap.weight).font(.headline).foregroundStyle(LogColor.ink)
                    }
                }
                .font(.subheadline)
                Button("Delete photo", role: .destructive) { confirm = true }
            }
            .padding(LogMetric.gutter)
            .background(LogColor.bg.ignoresSafeArea())
            .navigationTitle("Progress photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Delete photo", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes it from your log.")
            }
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            else { parent.onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
