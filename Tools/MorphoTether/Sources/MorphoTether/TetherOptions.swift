//
//  TetherOptions.swift
//  MorphoTether
//
//  Command-line options.
//

import CoreGraphics
import Foundation

struct TetherOptions {
    var mode: CaptureMode = .camera
    var port: UInt16 = 47810
    var maxSize: CGFloat = 1280
    var quality: CGFloat = 0.72
    var fps: Double = 30
    var deviceFilter: String?
    /// Clockwise degrees applied to every frame (0, 90, 180, 270).
    var rotation = 0
    /// Normalized crop with a top-left origin (x, y, width, height in 0…1).
    var crop: CGRect?
    var snapshotPath: String?
    var once = false
    var descriptorPath: String?
    var listDevices = false
    var showHelp = false

    enum ParseError: Error, CustomStringConvertible {
        case missingValue(String)
        case badValue(String, String)
        case unknownOption(String)

        var description: String {
            switch self {
            case .missingValue(let flag): "\(flag) needs a value"
            case .badValue(let flag, let value): "\(flag): can't parse '\(value)'"
            case .unknownOption(let flag): "unknown option \(flag)"
            }
        }
    }

    static let usage = """
    usage: MorphoTether [options]
      --mode camera|screen camera = the phone's camera via Continuity Camera (default)
                           screen = the phone's display, like QuickTime
      --port <n>           loopback TCP port (default 47810; 0 = ephemeral)
      --max-size <px>      downscale so the longest side is at most this (default 1280)
      --quality <0-1>      JPEG quality (default 0.72)
      --fps <n>            frame-rate cap (default 30)
      --device <name>      pick the iPhone whose name contains <name>
      --rotate <deg>       rotate frames clockwise: 0, 90, 180, 270
      --crop x,y,w,h       normalized crop, top-left origin (e.g. 0,0.12,1,0.66)
      --snapshot <path>    write the next frame as a JPEG to <path>
      --once               exit right after writing the snapshot
      --descriptor <path>  where to publish port + token
                           (default ~/Library/Application Support/Morpho/tether.json)
      --list               list iOS screen-capture devices and exit
      --help
    """

    static func parse(_ arguments: [String]) throws -> TetherOptions {
        var options = TetherOptions()
        var iterator = arguments.makeIterator()

        func value(for flag: String) throws -> String {
            guard let next = iterator.next() else { throw ParseError.missingValue(flag) }
            return next
        }

        while let flag = iterator.next() {
            switch flag {
            case "--mode":
                let raw = try value(for: flag)
                guard let mode = CaptureMode(rawValue: raw.lowercased()) else { throw ParseError.badValue(flag, raw) }
                options.mode = mode
            case "--rotate":
                let raw = try value(for: flag)
                guard let degrees = Int(raw), [0, 90, 180, 270].contains(degrees) else { throw ParseError.badValue(flag, raw) }
                options.rotation = degrees
            case "--port":
                let raw = try value(for: flag)
                guard let port = UInt16(raw) else { throw ParseError.badValue(flag, raw) }
                options.port = port
            case "--max-size":
                let raw = try value(for: flag)
                guard let size = Double(raw), size > 0 else { throw ParseError.badValue(flag, raw) }
                options.maxSize = size
            case "--quality":
                let raw = try value(for: flag)
                guard let quality = Double(raw), (0.05...1).contains(quality) else { throw ParseError.badValue(flag, raw) }
                options.quality = quality
            case "--fps":
                let raw = try value(for: flag)
                guard let fps = Double(raw), fps > 0 else { throw ParseError.badValue(flag, raw) }
                options.fps = fps
            case "--device":
                options.deviceFilter = try value(for: flag)
            case "--crop":
                let raw = try value(for: flag)
                let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4, parts[2] > 0, parts[3] > 0,
                      parts[0] >= 0, parts[1] >= 0, parts[0] + parts[2] <= 1, parts[1] + parts[3] <= 1
                else { throw ParseError.badValue(flag, raw) }
                options.crop = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            case "--snapshot":
                options.snapshotPath = try value(for: flag)
            case "--once":
                options.once = true
            case "--descriptor":
                options.descriptorPath = try value(for: flag)
            case "--list":
                options.listDevices = true
            case "--help", "-h":
                options.showHelp = true
            default:
                throw ParseError.unknownOption(flag)
            }
        }
        return options
    }
}

enum Log {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: String) { emit("INFO ", message) }
    static func error(_ message: String) { emit("ERROR", message) }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
