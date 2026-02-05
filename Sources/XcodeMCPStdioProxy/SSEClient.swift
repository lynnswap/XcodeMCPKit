import Foundation

final class SSEClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private let request: URLRequest
    private let parser = SSEParser()
    private let onData: (Data) -> Void
    private let onError: (Error) -> Void
    private var task: URLSessionDataTask?

    init(
        request: URLRequest,
        onData: @escaping (Data) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.request = request
        self.onData = onData
        self.onError = onError
        super.init()
    }

    func start() {
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let messages = parser.append(data)
        for message in messages {
            onData(message)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onError(error)
        }
    }
}
