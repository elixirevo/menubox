// SPDX-License-Identifier: GPL-3.0-only
// MenuBox project-owned code. See LICENSE and TRADEMARKS.md for GPL section 7 terms.

import Foundation

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

guard CommandLine.arguments.count >= 4 else {
    fail("Usage: create_icns.swift <output.icns> <type:path> [<type:path> ...]")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
var payload = Data()

for argument in CommandLine.arguments.dropFirst(2) {
    guard let separatorIndex = argument.firstIndex(of: ":") else {
        fail("Invalid chunk argument: \(argument)")
    }

    let type = String(argument[..<separatorIndex])
    guard type.utf8.count == 4 else {
        fail("ICNS chunk type must be exactly 4 bytes: \(type)")
    }

    let pathStart = argument.index(after: separatorIndex)
    let path = String(argument[pathStart...])
    let fileURL = URL(fileURLWithPath: path)

    let pngData: Data
    do {
        pngData = try Data(contentsOf: fileURL)
    } catch {
        fail("Unable to read \(path): \(error)")
    }

    guard pngData.starts(with: [0x89, 0x50, 0x4e, 0x47]) else {
        fail("ICNS chunk source is not a PNG: \(path)")
    }

    payload.append(contentsOf: type.utf8)
    appendBigEndianUInt32(UInt32(pngData.count + 8), to: &payload)
    payload.append(pngData)
}

var output = Data()
output.append(contentsOf: "icns".utf8)
appendBigEndianUInt32(UInt32(payload.count + 8), to: &output)
output.append(payload)

do {
    try output.write(to: outputURL)
} catch {
    fail("Unable to write \(outputURL.path): \(error)")
}
