import AVFoundation
import SwiftUI
import UIKit

/// Scan the pairing code Cindy shows on the PC (tray icon > Pair a phone or app), or paste it.
/// onCode returns true when the code was good (the sheet then closes).
struct CindyPairingScanner: View {
    let onCode: (String) -> Bool
    let cancel: () -> Void
    @State private var problem = ""
    @State private var cameraDenied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("On your PC: right-click Cindy's tray icon > Pair a phone or app, then point the camera at the code.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if cameraDenied {
                    Text("\(Cindy.shared.appName) can't use the camera. Allow it in iOS Settings, or paste the code instead.")
                        .font(.footnote).foregroundStyle(.orange)
                } else {
                    QRCamera { code in
                        if !onCode(code) { problem = "That isn't a Cindy pairing code." }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Button("Paste a code instead") {
                    let text = UIPasteboard.general.string ?? ""
                    if text.isEmpty || !onCode(text) { problem = "The clipboard doesn't hold a Cindy pairing code." }
                }
                if !problem.isEmpty { Text(problem).font(.footnote).foregroundStyle(.red) }
                Spacer()
            }
            .padding()
            .navigationTitle("Link with Cindy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .notDetermined: cameraDenied = !(await AVCaptureDevice.requestAccess(for: .video))
                case .authorized: cameraDenied = false
                default: cameraDenied = true
                }
            }
        }
    }
}

/// The camera, reporting each QR code it sees once.
private struct QRCamera: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> Scanner { Scanner(found: found) }
    func updateUIViewController(_ vc: Scanner, context: Context) {}

    final class Scanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let found: (String) -> Void
        private var last = ""

        init(found: @escaping (String) -> Void) {
            self.found = found
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.forEach { $0.frame = view.bounds }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code != last else { return }
            last = code
            found(code)
        }
    }
}
