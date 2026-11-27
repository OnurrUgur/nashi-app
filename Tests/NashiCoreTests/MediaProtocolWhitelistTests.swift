import XCTest
@testable import NashiCore

/// ffmpeg applies input options such as -protocol_whitelist only to the next -i.
/// Records the real command line through the NASHI_FFMPEG/NASHI_FFPROBE seam.
final class MediaProtocolWhitelistTests: XCTestCase {
    func testStillImageVisualizationWhitelistsEveryInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nashi-whitelist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("argv.log"), probe = root.appendingPathComponent("probe.json")
        try Data(#"{"format":{"duration":"10"},"streams":[{"index":0,"codec_type":"audio","codec_name":"mp3","channels":2,"sample_rate":"44100"}]}"#.utf8).write(to: probe)
        let ffprobe = root.appendingPathComponent("ffprobe"), ffmpeg = root.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\ncat '\(probe.path)'\n".utf8).write(to: ffprobe)
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '\(log.path)'; done\nfor last; do :; done\nprintf x > \"$last\"\n".utf8).write(to: ffmpeg)
        for (variable, tool) in [("NASHI_FFPROBE", ffprobe), ("NASHI_FFMPEG", ffmpeg)] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let previous = ProcessInfo.processInfo.environment[variable]
            setenv(variable, tool.path, 1)
            addTeardownBlock { if let previous { setenv(variable, previous, 1) } else { unsetenv(variable) } }
        }
        let audio = root.appendingPathComponent("Song.mp3"), image = root.appendingPathComponent("Cover.png")
        try Data([1]).write(to: audio); try Data([1]).write(to: image)
        var options = OperationOptions()
        options.visualizationStyle = "still image"; options.visualizationImage = image
        options.outputDirectory = root.appendingPathComponent("out")
        _ = try MediaEngine.tool(.audioToVideo, inputs: [audio], options: options, token: .init())

        let argv = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        var whitelisted = false, inputs: [String] = []
        for (index, argument) in argv.enumerated() {
            if argument == "-protocol_whitelist" { XCTAssertEqual(argv[index + 1], "file,pipe,crypto,data"); whitelisted = true }
            if argument == "-i" { XCTAssertTrue(whitelisted, "\(argv[index + 1]) has no protocol whitelist"); whitelisted = false; inputs.append(argv[index + 1]) }
        }
        XCTAssertEqual(inputs, [image.path, audio.path])
    }

    func testAudioTrimWithCoverArtWhitelistsEveryInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nashi-whitelist-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("argv.log"), probe = root.appendingPathComponent("probe.json")
        try Data(#"{"format":{"duration":"30","format_name":"mp3"},"streams":[{"index":0,"codec_type":"audio","codec_name":"mp3","channels":2,"sample_rate":"44100","duration":"30"},{"index":1,"codec_type":"video","codec_name":"mjpeg","width":300,"height":300,"disposition":{"attached_pic":1}}]}"#.utf8).write(to: probe)
        let ffprobe = root.appendingPathComponent("ffprobe"), ffmpeg = root.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\ncat '\(probe.path)'\n".utf8).write(to: ffprobe)
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '\(log.path)'; done\nfor last; do :; done\nprintf x > \"$last\"\n".utf8).write(to: ffmpeg)
        for (variable, tool) in [("NASHI_FFPROBE", ffprobe), ("NASHI_FFMPEG", ffmpeg)] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let previous = ProcessInfo.processInfo.environment[variable]
            setenv(variable, tool.path, 1)
            addTeardownBlock { if let previous { setenv(variable, previous, 1) } else { unsetenv(variable) } }
        }
        let audio = root.appendingPathComponent("Song.mp3")
        try Data([1]).write(to: audio)
        var options = OperationOptions()
        options.start = 5; options.end = 15
        options.outputDirectory = root.appendingPathComponent("out")
        _ = try MediaEngine.tool(.trimAudio, inputs: [audio], options: options, token: .init())

        let argv = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        var whitelisted = false, inputs: [String] = []
        for (index, argument) in argv.enumerated() {
            if argument == "-protocol_whitelist" { XCTAssertEqual(argv[index + 1], "file,pipe,crypto,data"); whitelisted = true }
            if argument == "-i" { XCTAssertTrue(whitelisted, "\(argv[index + 1]) has no protocol whitelist"); whitelisted = false; inputs.append(argv[index + 1]) }
        }
        XCTAssertEqual(inputs, [audio.path, audio.path])
    }

    func testProcessRunnerWhitelistsSecondInputWhenOnlyFirstHasWhitelist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nashi-whitelist-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("argv.log")
        let ffmpeg = root.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '\(log.path)'; done\n".utf8).write(to: ffmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)

        _ = try ProcessRunner.run(ffmpeg, ["-protocol_whitelist", "file,pipe,crypto,data", "-i", "first.mp3", "-i", "second.mp3", "-f", "null", "-"])
        let argv = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        var whitelisted = false, inputs: [String] = []
        for (index, argument) in argv.enumerated() {
            if argument == "-protocol_whitelist" { XCTAssertEqual(argv[index + 1], "file,pipe,crypto,data"); whitelisted = true }
            if argument == "-i" { XCTAssertTrue(whitelisted, "\(argv[index + 1]) has no protocol whitelist"); whitelisted = false; inputs.append(argv[index + 1]) }
        }
        XCTAssertEqual(inputs, ["first.mp3", "second.mp3"])
    }
}
