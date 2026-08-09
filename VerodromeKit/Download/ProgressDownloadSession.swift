import Foundation

/// Downloads a single remote file while reporting byte progress via a continuation.
final class ProgressDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession!
    private var isCancelled = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progressHandler = onProgress
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if isCancelled {
                continuation.resume(throwing: CancellationError())
                self.continuation = nil
                return
            }
            session.downloadTask(with: url).resume()
        }
    }

    /// Tears down the underlying session so a force-quit / offline flip doesn't leave
    /// URLSession work holding the process open.
    func cancel() {
        isCancelled = true
        session.invalidateAndCancel()
        if let continuation {
            continuation.resume(throwing: CancellationError())
            self.continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: temp)
            continuation?.resume(returning: temp)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
