import Foundation
import Virtualization

/// Finding and downloading Apple's macOS restore image (IPSW) for the VM.
public enum RestoreImage {
    public struct Info: Sendable {
        public let url: URL
        public let buildVersion: String
        public let osVersion: String
    }

    /// The newest macOS that this Mac can virtualize, as Apple publishes it.
    public static func latestSupported() async throws -> Info {
        let image = try await VZMacOSRestoreImage.latestSupported
        let v = image.operatingSystemVersion
        return Info(url: image.url, buildVersion: image.buildVersion,
                    osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    /// Loads a downloaded image and checks that this Mac can install it.
    public static func load(_ file: URL) async throws -> (VZMacOSRestoreImage, VZMacOSConfigurationRequirements) {
        let image = try await VZMacOSRestoreImage.image(from: file)
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw VMBundleError.unsupportedHost("macOS \(image.buildVersion) can't run in a VM on this Mac.")
        }
        guard requirements.hardwareModel.isSupported else {
            throw VMBundleError.unsupportedHost("macOS \(image.buildVersion) needs a different Mac.")
        }
        guard image.operatingSystemVersion.majorVersion >= 27 else {
            throw VMBundleError.unsupportedHost("the workspace needs macOS 27 or later in the VM (found \(image.buildVersion)).")
        }
        return (image, requirements)
    }
}

/// A resumable download into a directory: the partial file survives restarts and continues with an
/// HTTP range request. Reports progress as (received, total).
public final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (Int64, Int64) -> Void

    private let source: URL
    private let destination: URL
    private let partial: URL
    private let progress: Progress
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var lastReport = Date.distantPast

    public init(source: URL, destination: URL, progress: @escaping Progress) {
        self.source = source
        self.destination = destination
        self.partial = destination.appendingPathExtension("partial")
        self.progress = progress
    }

    public func run() async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.start()
        }
    }

    public func cancel() { session?.invalidateAndCancel() }

    private func start() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) {
            fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        received = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: source)
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session?.dataTask(with: request).resume()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            if http.statusCode == 206 {
                handle = try FileHandle(forWritingTo: partial)
                try handle?.seekToEnd()
            } else if http.statusCode == 200 {
                // The server ignored the range (or this is a fresh start): begin again.
                received = 0
                try Data().write(to: partial)
                handle = try FileHandle(forWritingTo: partial)
            } else {
                finish(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey:
                    "The download server answered \(http.statusCode)."])))
                completionHandler(.cancel)
                return
            }
        } catch {
            finish(.failure(error)); completionHandler(.cancel); return
        }
        total = received + max(0, http.expectedContentLength)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { finish(.failure(error)); dataTask.cancel(); return }
        received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.5 {
            lastReport = now
            progress(received, total)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error { finish(.failure(error)); return }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
            progress(received, total)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        cont.resume(with: result)
    }
}
