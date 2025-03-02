import AppKit
import Foundation

public protocol TerminalType {
    func streamCommand(
        _ command: String,
        arguments: [String],
        currentDirectoryPath: String,
        environment: [String: String]
    ) -> AsyncThrowingStream<String, Error>

    func runCommand(
        _ command: String,
        arguments: [String],
        currentDirectoryPath: String,
        environment: [String: String]
    ) async throws -> String

    func terminate() async
    func writeInput(_ input: String) async
    var isRunning: Bool { get }
}

public final class Terminal: TerminalType, @unchecked Sendable {
    var process: Process?
    var outputPipe: Pipe?
    var inputPipe: Pipe?
    
    public var isRunning: Bool { process?.isRunning ?? false }

    public struct TerminationError: Error {
        public let reason: Process.TerminationReason
        public let status: Int32
    }

    public init() {}

    func getEnvironmentVariables() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
            .merging(["LANG": "en_US.UTF-8"], uniquingKeysWith: { $1 })
        return env
    }

    public func streamCommand(
        _ command: String = "/bin/bash",
        arguments: [String],
        currentDirectoryPath: String = "/",
        environment: [String: String]
    ) -> AsyncThrowingStream<String, Error> {
        self.process?.terminate()
        let process = Process()
        self.process = process

        process.launchPath = command
        process.currentDirectoryPath = currentDirectoryPath
        process.arguments = arguments
        process.environment = getEnvironmentVariables()
            .merging(environment, uniquingKeysWith: { $1 })

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        self.outputPipe = outputPipe

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        self.inputPipe = inputPipe

        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        let contentStream = AsyncThrowingStream<String, Error> { cont in
            continuation = cont
        }

        Task { [continuation, self] in
            let notificationCenter = NotificationCenter.default
            let notifications = notificationCenter.notifications(
                named: FileHandle.readCompletionNotification,
                object: outputPipe.fileHandleForReading
            )
            for await notification in notifications {
                let userInfo = notification.userInfo
                if let data = userInfo?[NSFileHandleNotificationDataItem] as? Data,
                   let content = String(data: data, encoding: .utf8),
                   !content.isEmpty
                {
                    continuation?.yield(content)
                }
                if !(self.process?.isRunning ?? false) {
                    let reason = self.process?.terminationReason ?? .exit
                    let status = self.process?.terminationStatus ?? 1
                    if let output = (self.process?.standardOutput as? Pipe)?.fileHandleForReading
                        .readDataToEndOfFile(),
                        let content = String(data: output, encoding: .utf8),
                        !content.isEmpty
                    {
                        continuation?.yield(content)
                    }

                    if status == 0 {
                        continuation?.finish()
                    } else {
                        continuation?.finish(throwing: TerminationError(
                            reason: reason,
                            status: status
                        ))
                    }
                    break
                }
                Task { @MainActor in
                    outputPipe.fileHandleForReading.readInBackgroundAndNotify(forModes: [.common])
                }
            }
        }

        Task { @MainActor in
            outputPipe.fileHandleForReading.readInBackgroundAndNotify(forModes: [.common])
        }

        do {
            try process.run()
        } catch {
            continuation.finish(throwing: error)
        }

        return contentStream
    }

    public func runCommand(
        _ command: String = "/bin/bash",
        arguments: [String],
        currentDirectoryPath: String = "/",
        environment: [String: String]
    ) async throws -> String {
        let stream = streamCommand(
            command,
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath,
            environment: environment
        )
        var result = ""
        for try await output in stream {
            result += output
        }
        return result
    }

    public func writeInput(_ input: String) {
        guard let data = input.data(using: .utf8) else {
            return
        }

        inputPipe?.fileHandleForWriting.write(data)
        inputPipe?.fileHandleForWriting.closeFile()
    }

    public func terminate() async {
        process?.terminate()
        process = nil
    }
}
