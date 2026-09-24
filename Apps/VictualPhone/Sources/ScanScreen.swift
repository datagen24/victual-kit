import PhotosUI
import SwiftUI
import VictualCore
import VictualStock

/// The tab the app opens on: point the camera at something, and act on it.
///
/// The result is a card over the camera rather than a sheet, deliberately. The
/// camera keeps running under it, so the next package can be scanned straight
/// away — reading a second code replaces the card — and a booking form can
/// still be presented, which a sheet already on screen would prevent.
struct ScanScreen: View {
    let workspace: PhoneWorkspace

    @State private var camera: CameraAccess.Status?
    @State private var isTypingCode = false
    @State private var typedCode = ""
    @State private var photo: PhotosPickerItem?
    @State private var photoMessage: String?
    @State private var scanCount = 0

    private var scanner: ScanStore { workspace.scanner }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                cameraLayer
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    if scanner.phase != .idle {
                        ScanResultCard(workspace: workspace)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    UndoBar(bookings: workspace.bookings) { await workspace.undoLastBooking() }
                }
            }
            .animation(.snappy, value: scanner.phase)
            .animation(.snappy, value: workspace.bookings.canUndoLast)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(for: ScanDestination.self) { destination in
                switch destination {
                case .product(let id):
                    ProductScreen(workspace: workspace, productID: id)
                case .location(let target):
                    LocationScreen(workspace: workspace, location: target)
                }
            }
        }
        .task { camera = await CameraAccess.request() }
        .sensoryFeedback(.success, trigger: scanCount)
        .alert("Type a code", isPresented: $isTypingCode) {
            TextField("Barcode or label", text: $typedCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Look up") { submitTyped() }
            Button("Cancel", role: .cancel) { typedCode = "" }
        } message: {
            Text("For a code the camera cannot read — the digits under a barcode, or a label's code.")
        }
        .alert(
            "No code found",
            isPresented: Binding(get: { photoMessage != nil }, set: { if !$0 { photoMessage = nil } })
        ) {
            Button("OK", role: .cancel) { photoMessage = nil }
        } message: {
            Text(photoMessage ?? "")
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await read(item) }
        }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraLayer: some View {
        switch camera {
        case .granted where LiveBarcodeScanner.isSupported:
            LiveBarcodeScanner(isActive: workspace.presentedBooking == nil) { payload in
                if scanner.submit(payload) { scanCount += 1 }
            }
        case .denied:
            CameraUnavailable(
                title: "Camera access is off",
                message: "Allow the camera in Settings to scan, or type a code or pick a photo instead.",
                showsSettingsLink: true
            )
        case .granted, .unavailable:
            CameraUnavailable(
                title: "No camera scanner here",
                message: "This device cannot scan live. Type a code, or pick a photo of one.",
                showsSettingsLink: false
            )
        case nil:
            Color.black
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Scan a photo", systemImage: "photo")
            }
            Button {
                isTypingCode = true
            } label: {
                Label("Type a code", systemImage: "keyboard")
            }
        }
    }

    // MARK: - Other ways in

    private func submitTyped() {
        let code = typedCode
        typedCode = ""
        if scanner.submit(code, force: true) { scanCount += 1 }
    }

    private func read(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                photoMessage = "That photo could not be opened."
                return
            }
            guard let payload = try await PhotoBarcodeReader.payloads(in: data).first else {
                photoMessage = "There is no barcode or label in that photo that could be read."
                return
            }
            if scanner.submit(payload, force: true) { scanCount += 1 }
        } catch {
            photoMessage = "That photo could not be read: \(error.localizedDescription)"
        }
    }
}

/// Where a scan result can lead.
enum ScanDestination: Hashable {
    case product(Int)
    case location(LabelTarget)
}

/// What the scan tab shows instead of a camera.
private struct CameraUnavailable: View {
    let title: String
    let message: String
    let showsSettingsLink: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "camera.metering.unknown")
        } description: {
            Text(message)
        } actions: {
            if showsSettingsLink {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 60)
        .background(Color(.systemGroupedBackground))
    }
}
