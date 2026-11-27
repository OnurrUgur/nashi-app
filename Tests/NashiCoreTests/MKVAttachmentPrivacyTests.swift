import XCTest
@testable import NashiCore

final class MKVAttachmentPrivacyTests: XCTestCase {
    private func runFFmpeg(_ arguments: [String]) throws {
        try ProcessRunner.run(
            Dependencies.executable("ffmpeg"),
            ["-hide_banner", "-nostdin", "-v", "error", "-n"] + arguments
        )
    }

    private func attachmentFile(in directory: URL) throws -> URL {
        let output = directory.appendingPathComponent("private-notes.txt")
        try Data("Private sidecar notes".utf8).write(to: output)
        return output
    }

    private func mkvWithAttachment(in directory: URL) throws -> URL {
        let note = try attachmentFile(in: directory)
        let output = directory.appendingPathComponent("PrivateClip.mkv")
        try runFFmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=8:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-attach", note.path,
            "-metadata:s:t", "mimetype=text/plain",
            "-metadata:s:t", "filename=private-notes.txt",
            "-metadata", "title=Private title",
            output.path
        ])
        return output
    }

    func testRemoveAllDropsMKVAttachmentStreamsAndRetainsVideoAndAudio() throws {
        let directory = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try mkvWithAttachment(in: directory)
        let original = try Data(contentsOf: source)

        let before = try MediaEngine.inspect(source)
        XCTAssertEqual(before.streams.filter { $0.kind == "attachment" }.count, 1)

        var options = OperationOptions()
        options.metadataRemoveAll = true
        options.outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        let output = try XCTUnwrap(ConversionEngine.run(.init(inputs: [source], operation: .tool(.removeMetadata), options: options)).first)

        let after = try MediaEngine.inspect(output)
        XCTAssertTrue(after.streams.filter { $0.kind == "attachment" }.isEmpty, "MKV attachment streams survived Remove All")
        XCTAssertTrue(after.hasVideo)
        XCTAssertTrue(after.hasAudio)
        XCTAssertFalse(try MediaEngine.readMetadata(output).values.contains { $0.contains("Private") })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testEditingSingleTagRetainsMKVAttachmentWhenRemoveAllIsFalse() throws {
        let directory = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try mkvWithAttachment(in: directory)
        let original = try Data(contentsOf: source)

        var options = OperationOptions()
        options.outputDirectory = directory.appendingPathComponent("out-edit", isDirectory: true)
        let output = try XCTUnwrap(MediaEngine.editMetadata(source, metadata: ["file:title": "Public title"], removeAll: false, options: options).first)

        let after = try MediaEngine.inspect(output)
        XCTAssertEqual(after.streams.filter { $0.kind == "attachment" }.count, 1)
        XCTAssertEqual(try MediaEngine.readMetadata(output)["file:title"], "Public title")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testRemoveAllRemapsTrackMetadataIndexPastDroppedAttachmentStream() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nashi-mkv-remap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let log = root.appendingPathComponent("argv.log")
        let probe = root.appendingPathComponent("probe.json")
        let json = #"{"format":{"duration":"10","format_name":"matroska,webm"},"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":64,"height":48},{"index":1,"codec_type":"attachment","codec_name":"mjpeg"},{"index":2,"codec_type":"audio","codec_name":"aac","channels":2,"sample_rate":"48000"}]}"#
        try Data(json.utf8).write(to: probe)

        let ffprobe = root.appendingPathComponent("ffprobe")
        let ffmpeg = root.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\ncat '\(probe.path)'\n".utf8).write(to: ffprobe)
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '\(log.path)'; done\nfor last; do :; done\nprintf x > \"$last\"\n".utf8).write(to: ffmpeg)
        for (variable, tool) in [("NASHI_FFPROBE", ffprobe), ("NASHI_FFMPEG", ffmpeg)] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let previous = ProcessInfo.processInfo.environment[variable]
            setenv(variable, tool.path, 1)
            addTeardownBlock { if let previous { setenv(variable, previous, 1) } else { unsetenv(variable) } }
        }

        let input = root.appendingPathComponent("Clip.mkv")
        try Data([1]).write(to: input)
        var options = OperationOptions()
        options.outputDirectory = root.appendingPathComponent("out", isDirectory: true)
        options.metadataRemoveAll = true
        options.metadata = ["track[2]:language": "eng"]
        _ = try ConversionEngine.run(.init(inputs: [input], operation: .tool(.removeMetadata), options: options))

        let argv = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(argv.contains("-0:t?"), "Expected -map -0:t? in ffmpeg args: \(argv)")
        XCTAssertTrue(argv.contains("-metadata:s:1"), "Expected audio stream index 2 to remap to 1 after dropping attachment stream 1: \(argv)")
        XCTAssertFalse(argv.contains("-metadata:s:2"))
    }
}
