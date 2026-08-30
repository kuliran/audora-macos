import Foundation

let labels = ["nominal", "fair", "serious", "critical"]
let rawValue = ProcessInfo.processInfo.thermalState.rawValue

guard labels.indices.contains(rawValue) else {
    FileHandle.standardError.write(Data("unknown thermal state\n".utf8))
    exit(2)
}

print(labels[rawValue])
