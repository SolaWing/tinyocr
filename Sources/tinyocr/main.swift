import ArgumentParser
import Cocoa
import Vision
import Foundation
import Logging

@available(macOS 13.0, *)

struct tinyocr: ArgumentParser.ParsableCommand {
    static let logger = {
        var logger = Logger(label: "tinyocr", factory: StreamLogHandler.standardError(label:metadataProvider:))
        let level = ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased()
        if let level {
            if let level = Logger.Level(rawValue: level) {
                logger.logLevel = level
            } else {
                switch level {
                case "warn": logger.logLevel = .warning
                case "fatal": logger.logLevel = .critical
                default: break // unknown level, ignore it
                }
            }
        }
        return logger
    }

    public static let configuration = CommandConfiguration(abstract: "Perform OCR on every image passed a command line argument, output to stdout")

    @Option
    var lang: [String] = ["en"]

    @Option(help: "Custom word list from file",
            completion: .file(extensions: ["txt"]))
    var words: String?

    @Argument(completion: .file(extensions: ["jpeg","jpg","png","tiff"])) // support more?
    var files: [String] = []

    @Flag(help: """
          server mode. interact by packet, stderr as log. server mode shouldn't set files.
          packet should be: 4 bytes length(LE), and then data.
          input data should be a json package. eg: {"cmd": "cmd", "otherparams"}
          output data according to cmd. (response data may be zero length, check length == 0 please).
          now input and output as follow:
            {"cmd": "file", "file": "path", "lang": ["en"]} => ocr text
            {"cmd": "exit"} => no response
          """)
    var server: Bool = false

    mutating func run() throws {
        if !files.isEmpty { try run(files: files) }
        else if server { try serve() }
    }

    func run(files: [String]) throws {
        let words = try words.flatMap { try String(contentsOfFile: $0).components(separatedBy: "\n") }
        let translator = OCRTranslator(lang: lang, words: words ?? [])
        for path in files {
            print(translator.traslate(path: path))
        }
    }

    enum ServeError: Error {
    case nopacket
    case nodata
    case invalidJSON
    }
    func serve() throws {
        let words = try words.flatMap { try String(contentsOfFile: $0).components(separatedBy: "\n") }
        let translator = OCRTranslator(lang: lang, words: words ?? [])

        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        func getPacket() throws -> [String: Any] {
            guard let _length = try stdin.read(upToCount: 4) else {
                throw ServeError.nopacket
            }
            let length = _length.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard let _json = try stdin.read(upToCount: Int(length)) else {
                throw ServeError.nodata
            }
            guard let json = try JSONSerialization.jsonObject(with: _json) as? [String: Any] else {
                throw ServeError.invalidJSON
            }
            return json
        }
        func writePacket(data: Data) throws {
            let length = withUnsafeBytes(of: UInt32(data.count).littleEndian) { Data($0) }
            Self.logger.info("<== \(length.map { String(format: "%02X", $0) }.joined()) \(data.count)")
            try stdout.write(contentsOf: length)
            try stdout.write(contentsOf: data)
        }


        Self.logger.info("tinyocr server started!")
        server: while true {
            do {
                let packet = try getPacket()
                guard let cmd = packet["cmd"] as? String else {
                    Self.logger.warning("unknown cmd packet")
                    continue
                }
                Self.logger.info("==> \(cmd)")
                switch cmd {
                case "file":
                    guard let file = packet["file"] as? String else {
                        Self.logger.warning("no file in packet!")
                        continue
                    }
                    let output = translator.traslate(path: file, lang: packet["lang"] as? [String]).data(using: .utf8)!
                    try writePacket(data: output)
                case "exit":
                    break server
                default: continue
                }
            } catch ServeError.invalidJSON {
                Self.logger.warning("invalid json!")
            } catch {
                Self.logger.warning("\(error)")
                throw error
            }
        }
        Self.logger.info("tinyocr server stoped!")
    }
    struct TextOutputHandler: TextOutputStream {
        let value: FileHandle
        mutating func write(_ string: String) {
            try! value.write(contentsOf: string.data(using: .utf8)!)
        }
    }
    class OCRTranslator {
        var request: VNRecognizeTextRequest!
        var output = ""
        let defaultLang: [String]
        init(lang: [String], words: [String]) {
            defaultLang = lang
            request = VNRecognizeTextRequest { [weak self](request, error) in
                guard let self else { return }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // take the most likely result for each chunk, then send them all the stdout
                let obs : [String] = observations.map { $0.topCandidates(1).first?.string ?? ""}
                output.append(obs.joined(separator: "\n"))
            }
            request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
            request.usesLanguageCorrection = true
            request.revision = VNRecognizeTextRequestRevision3
            if !words.isEmpty {
                request.customWords = words
            }
        }
        func traslate(path: String, lang: [String]? = nil) -> String {
            let url = URL(filePath: path)
            guard (try? url.checkResourceIsReachable()) == true else { return "" }

            guard let imgRef = NSImage(byReferencing: url).cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fatalError("Error: could not convert NSImage to CGImage - '\(url)'")
            }
            output = ""
            request.recognitionLanguages = lang ?? defaultLang
            try? VNImageRequestHandler(cgImage: imgRef, options: [:]).perform([request])
            return output // write by request
        }
    }
}

if #available(macOS 13.0, *) {
    tinyocr.main()
} else {
    print("This code only runs on macOS 13.0 and higher")
}
