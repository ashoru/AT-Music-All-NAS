import Foundation

func atmusicLocalized(_ chinese: String, _ english: String) -> String { chinese }

struct LocalPlaylist {
    var songs: [Song]
}

final class ATMusicLogger {
    static let shared = ATMusicLogger()
    enum Level { case warn }
    func log(_ message: String, level: Level) {}
}
