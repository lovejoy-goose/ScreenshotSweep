import AVFoundation

/// Camera adapter for the Capability Lab probe. Separate from the QR scanner.
struct SystemCameraAccess: CameraSystem {
    func hasCamera() async -> Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    func permission() async -> CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    func requestAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }

    func captureOneFrame() async throws {
        try await OneFrameCapture().run()
    }
}

/// Minimal capture session that waits for one video frame. The frame is never read,
/// copied, shown, saved or sent: its arrival is all the probe needs. The session stops
/// right after the first frame, on error and on cancellation.
private final class OneFrameCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.katana.connector.capability-lab.camera")
    private let oneShot = ProbeOneShot()

    func run() async throws {
        queue.async { self.configureAndStart() }
        defer { stop() }
        try await oneShot.wait()
    }

    private func configureAndStart() {
        guard !oneShot.isResolved else { return }
        session.beginConfiguration()
        session.sessionPreset = .low
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            oneShot.resolve(.failure(CapabilityProbeError.unavailable))
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            oneShot.resolve(.failure(CapabilityProbeError.systemError))
            return
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        oneShot.resolve(.success(()))
    }

    private func stop() {
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }
}
