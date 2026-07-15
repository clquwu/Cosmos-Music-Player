//
//  AudioEntity.swift
//  Cosmos Music Player
//
//  Union value so a single PlayAudioIntent handles "Play <song>",
//  "Play the album <title>", "Play some <artist>" and "Play my <playlist>".
//

#if canImport(MediaIntents)
import AppIntents

@available(iOS 27.0, *)
@UnionValue
enum AudioEntity {
    case song(SongEntity)
    case album(AlbumEntity)
    case artist(ArtistEntity)
    case playlist(PlaylistEntity)

    var title: String {
        switch self {
        case .song(let song):
            song.title
        case .album(let album):
            album.title
        case .artist(let artist):
            artist.name
        case .playlist(let playlist):
            playlist.title
        }
    }
}

#endif // canImport(MediaIntents)
