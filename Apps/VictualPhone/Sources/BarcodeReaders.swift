import AVFoundation
import SwiftUI
import Vision
import VisionKit

/// The symbologies worth looking for, in both readers.
///
/// Retail barcodes, because that is what is on a package, and the two matrix
/// codes Victual's own labels use: QR for new `vctl:` labels, DataMatrix for
/// the legacy Grocycodes the server still reads (ADR-0011's open question 2).
/// Nothing else — every extra symbology is another way to misread a smudge.
enum ScannedSymbologies {
    static let all: [VNBarcodeSymbology] = [
        .ean13, .ean8, .upce,
        .code128, .code39, .code93, .itf14,
        .gs1DataBar, .gs1DataBarExpanded,
        .qr, .dataMatrix,
    ]
}

/// The live camera scanner.
///
/// VisionKit's `DataScannerViewController` rather than a hand-built
/// `AVCaptureSession`: it brings guidance, highlighting and pinch-to-zoom for
/// free, and — the reason that matters — it is what Apple tunes for reading
/// codes at an angle on a curved package. It needs an A12 or later and a
/// camera, which is why ``isSupported`` exists and why the scan screen has a
/// fallback. It is not supported in the simulator at all.
///
/// It reports each code when it first enters the frame. Repeats are the
/// `ScanStore`'s business, not this view's.
struct LiveBarcodeScanner: UIViewControllerRepresentable {
    /// Whether the camera should be running. Off while a form is up, so a
    /// package on the counter does not replace the thing being booked.
    var isActive: Bool
    var onScan: (String) -> Void

    @MainActor static var isSupported: Bool { DataScannerViewController.isSupported }
    @MainActor static var isAvailable: Bool { DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: ScannedSymbologies.all)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        if isActive, !scanner.isScanning {
            try? scanner.startScanning()
        } else if !isActive, scanner.isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onScan(payload)
                    return
                }
            }
        }

        /// A tap on a highlighted code is a person choosing it, so it is
        /// reported even if that code was already the last one read.
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                onScan(payload)
            }
        }
    }
}

/// Whether the camera may be used, asking the first time.
enum CameraAccess {
    enum Status {
        case granted, denied, unavailable
    }

    static func request() async -> Status {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}

/// Reads a barcode out of a still image.
///
/// For a code in a photo or a screenshot — a label someone messaged over, a
/// receipt — and for any device where the live scanner is unsupported. It is
/// also what makes scanning testable in the simulator, which has no camera.
enum PhotoBarcodeReader {
    /// The payloads found, most confident first. Empty when there are none.
    static func payloads(in imageData: Data) async throws -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = ScannedSymbologies.all.compactMap(BarcodeSymbology.init)
        let observations = try await request.perform(on: imageData)
        var seen = Set<String>()
        return observations
            .sorted { $0.confidence > $1.confidence }
            .compactMap(\.payloadString)
            .filter { seen.insert($0).inserted }
    }
}

extension BarcodeSymbology {
    /// Bridges the VisionKit spelling to the Swift Vision one, so both readers
    /// share one list.
    fileprivate init?(_ symbology: VNBarcodeSymbology) {
        switch symbology {
        case .ean13: self = .ean13
        case .ean8: self = .ean8
        case .upce: self = .upce
        case .code128: self = .code128
        case .code39: self = .code39
        case .code93: self = .code93
        case .itf14: self = .itf14
        case .gs1DataBar: self = .gs1DataBar
        case .gs1DataBarExpanded: self = .gs1DataBarExpanded
        case .qr: self = .qr
        case .dataMatrix: self = .dataMatrix
        default: return nil
        }
    }
}
