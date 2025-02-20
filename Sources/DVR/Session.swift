import Foundation

open class Session: URLSession {

    // MARK: - Properties

    public static var defaultTestBundle: Bundle? {
        return Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    }

    open var outputDirectory: String
    public let cassetteURL: URL?
    public let backingSession: URLSession
    open var recordingEnabled = true

    private let headersToCheck: [String]

    private var recording = false
    private var needsPersistence = false
    private var outstandingTasks = [URLSessionTask]()
    private var completedInteractions = [Interaction]()
    private var completionBlock: (() -> Void)?

    override open var delegate: URLSessionDelegate? {
        return backingSession.delegate
    }

    // MARK: - Initializers

    public init(outputDirectory: String = "~/Desktop/DVR/", cassetteURL: URL?, backingSession: URLSession = URLSession.shared, headersToCheck: [String] = []) {
        self.outputDirectory = outputDirectory
        self.cassetteURL = cassetteURL
        self.backingSession = backingSession
        self.headersToCheck = headersToCheck
        super.init()
    }

    convenience public init(outputDirectory: String = "~/Desktop/DVR/", cassetteName: String, testBundle: Bundle = Session.defaultTestBundle!, backingSession: URLSession = URLSession.shared, headersToCheck: [String] = []) {
        let cassetteURL = testBundle.url(forResource: cassetteName, withExtension: "json")
        self.init(outputDirectory: outputDirectory, cassetteURL: cassetteURL, backingSession: backingSession, headersToCheck: headersToCheck)
    }

    // MARK: - URLSession
    
    open override func dataTask(with url: URL) -> URLSessionDataTask {
        return addDataTask(URLRequest(url: url))
    }

    open override func dataTask(with url: URL, completionHandler: @escaping ((Data?, Foundation.URLResponse?, Error?) -> Void)) -> URLSessionDataTask {
        return addDataTask(URLRequest(url: url), completionHandler: completionHandler)
    }

    open override func dataTask(with request: URLRequest) -> URLSessionDataTask {
        return addDataTask(request)
    }

    open override func dataTask(with request: URLRequest, completionHandler: @escaping ((Data?, Foundation.URLResponse?, Error?) -> Void)) -> URLSessionDataTask {
        return addDataTask(request, completionHandler: completionHandler)
    }

    open override func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        return addDownloadTask(request)
    }

    open override func downloadTask(with request: URLRequest, completionHandler: @escaping (URL?, Foundation.URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        return addDownloadTask(request, completionHandler: completionHandler)
    }

    open override func uploadTask(with request: URLRequest, from bodyData: Data) -> URLSessionUploadTask {
        return addUploadTask(request, fromData: bodyData)
    }

    open override  func uploadTask(with request: URLRequest, from bodyData: Data?, completionHandler: @escaping (Data?, Foundation.URLResponse?, Error?) -> Void) -> URLSessionUploadTask {
        return addUploadTask(request, fromData: bodyData, completionHandler: completionHandler)
    }

    open override func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
        let data = try! Data(contentsOf: fileURL)
        return addUploadTask(request, fromData: data)
    }

    open override func uploadTask(with request: URLRequest, fromFile fileURL: URL, completionHandler: @escaping (Data?, Foundation.URLResponse?, Error?) -> Void) -> URLSessionUploadTask {
        let data = try! Data(contentsOf: fileURL)
        return addUploadTask(request, fromData: data, completionHandler: completionHandler)
    }

    open override func invalidateAndCancel() {
        recording = false
        outstandingTasks.removeAll()
        backingSession.invalidateAndCancel()
    }


    // MARK: - Recording

    /// You don’t need to call this method if you're only recoding one request.
    open func beginRecording() {
        if recording {
            return
        }

        recording = true
        needsPersistence = false
        outstandingTasks = []
        completedInteractions = []
        completionBlock = nil
    }

    /// This only needs to be called if you call `beginRecording`. `completion` will be called on the main queue after
    /// the completion block of the last task is called. `completion` is useful for fulfilling an expectation you setup
    /// before calling `beginRecording`.
    open func endRecording(_ completion: (() -> Void)? = nil) {
        if !recording {
            return
        }

        recording = false
        completionBlock = completion

        if outstandingTasks.count == 0 {
            finishRecording()
        }
    }


    // MARK: - Internal

    var cassette: Cassette? {
        guard let cassetteURL = cassetteURL,
            let data = try? Data(contentsOf: cassetteURL),
            let raw = try? JSONSerialization.jsonObject(with: data, options: []),
            let json = raw as? [String: Any]
        else { return nil }

        return Cassette(dictionary: json)
    }

    func finishTask(_ task: URLSessionTask, interaction: Interaction, playback: Bool) {
        needsPersistence = needsPersistence || !playback

        if let index = outstandingTasks.firstIndex(of: task) {
            outstandingTasks.remove(at: index)
        }

        completedInteractions.append(interaction)

        if !recording && outstandingTasks.count == 0 {
            finishRecording()
        }

        if let delegate = delegate as? URLSessionDataDelegate, let task = task as? URLSessionDataTask, let data = interaction.responseData {
            delegate.urlSession?(self, dataTask: task, didReceive: data as Data)
        }

        if let delegate = delegate as? URLSessionTaskDelegate {
            delegate.urlSession?(self, task: task, didCompleteWithError: nil)
        }
    }


    // MARK: - Private

    private func addDataTask(_ request: URLRequest, completionHandler: ((Data?, Foundation.URLResponse?, NSError?) -> Void)? = nil) -> URLSessionDataTask {
        let modifiedRequest = backingSession.configuration.httpAdditionalHeaders.map(request.appending) ?? request
        let task = SessionDataTask(session: self, request: modifiedRequest, headersToCheck: headersToCheck, completion: completionHandler)
        addTask(task)
        return task
    }

    private func addDownloadTask(_ request: URLRequest, completionHandler: SessionDownloadTask.Completion? = nil) -> URLSessionDownloadTask {
        let modifiedRequest = backingSession.configuration.httpAdditionalHeaders.map(request.appending) ?? request
        let task = SessionDownloadTask(session: self, request: modifiedRequest, completion: completionHandler)
        addTask(task)
        return task
    }

    private func addUploadTask(_ request: URLRequest, fromData data: Data?, completionHandler: SessionUploadTask.Completion? = nil) -> URLSessionUploadTask {
        var modifiedRequest = backingSession.configuration.httpAdditionalHeaders.map(request.appending) ?? request
        modifiedRequest = data.map(modifiedRequest.appending) ?? modifiedRequest
        let task = SessionUploadTask(session: self, request: modifiedRequest, completion: completionHandler)
        addTask(task.dataTask)
        return task
    }

    private func addTask(_ task: URLSessionTask) {
        let shouldRecord = !recording
        if shouldRecord {
            beginRecording()
        }

        outstandingTasks.append(task)

        if shouldRecord {
            endRecording()
        }
    }

    private func persist(_ interactions: [Interaction]) {
        defer {
            abort()
        }

        // Create directory
        let outputDirectory = (self.outputDirectory as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDirectory) {
            do {
              try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
              print("[DVR] Failed to create cassettes directory.")
            }
        }

        let cassetteName = cassetteURL?.deletingPathExtension().lastPathComponent ?? "cassette"
        let cassette = Cassette(name: cassetteName, interactions: interactions)

        // Persist


        do {
            let outputPath = ((outputDirectory as NSString).appendingPathComponent(cassetteName) as NSString).appendingPathExtension("json")!
            let data = try JSONSerialization.data(withJSONObject: cassette.dictionary, options: [.prettyPrinted])

            // Add trailing new line
            guard var string = NSString(data: data, encoding: String.Encoding.utf8.rawValue) else {
                print("[DVR] Failed to persist cassette.")
                return
            }
            string = string.appending("\n") as NSString

            if let data = string.data(using: String.Encoding.utf8.rawValue) {
                try? data.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
                print("[DVR] Persisted cassette at \(outputPath). Please add this file to your test target")
                return
            }

            print("[DVR] Failed to persist cassette.")
        } catch {
            print("[DVR] Failed to persist cassette.")
        }
    }

    private func finishRecording() {
        if needsPersistence {
            persist(completedInteractions)
        }

        // Clean up
        completedInteractions = []

        // Call session’s completion block
        completionBlock?()
    }
}
