import Foundation

enum LyricFetcher {
    static func load(for song: Song) async -> [LyricLine] {
        switch song.source {
        case .netease:
            return await loadFromNetease(id: song.id)
        case .qq:
            guard let mid = song.qqMid else { return [] }
            return await loadFromQQ(songmid: mid)
        case .kugou:
            guard let hash = song.kugouHash else { return [] }
            return await loadFromKugou(hash: hash, duration: song.duration)
        }
    }
    
    static func currentLine(in lyrics: [LyricLine], progress: Double) -> LyricLine? {
        guard !lyrics.isEmpty else { return nil }
        var candidate: LyricLine?
        for line in lyrics {
            if line.time > progress { break }
            candidate = line
        }
        return candidate
    }
    
    private static func loadFromNetease(id: Int) async -> [LyricLine] {
        do {
            let (lrc, tlyric) = try await NetEaseAPI.shared.lyricWithTranslation(id: id)
            guard let lrc = lrc else { return [] }
            return LyricParser.parse(lrc, translationRaw: tlyric)
        } catch {
            return []
        }
    }
    
    private static func loadFromQQ(songmid: String) async -> [LyricLine] {
        do {
            guard let lrc = try await QQMusicAPI.shared.lyric(songmid: songmid) else { return [] }
            return LyricParser.parse(lrc)
        } catch {
            return []
        }
    }
    
    private static func loadFromKugou(hash: String, duration: TimeInterval) async -> [LyricLine] {
        let lrc = await KugouMusicAPI.shared.lyric(hash: hash, duration: duration)
        return LyricParser.parse(lrc)
    }
}
