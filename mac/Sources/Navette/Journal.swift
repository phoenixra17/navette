import Foundation

/// Journal de diagnostic : ~/Library/Logs/Navette.log (les journaux système masquent le détail).
enum Journal {
    static func write(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Navette.log")
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
