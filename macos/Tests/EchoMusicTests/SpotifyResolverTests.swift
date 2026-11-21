import Foundation
import Testing
@testable import EchoMusic

@Suite struct SpotifyResolverTests {
    @Test func spotifyURLParsing() {
        let trackURL = URL(string: "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")!
        let parsedTrack = SpotifySource.parse(url: trackURL)
        #expect(parsedTrack?.type == "track")
        #expect(parsedTrack?.id == "4cOdK2wGLETKBW3PvgPWqT")

        let playlistURL = URL(string: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")!
        let parsedPlaylist = SpotifySource.parse(url: playlistURL)
        #expect(parsedPlaylist?.type == "playlist")
        #expect(parsedPlaylist?.id == "37i9dQZF1DXcBWIGoYBM5M")

        let uri = URL(string: "spotify:track:4cOdK2wGLETKBW3PvgPWqT")!
        let parsedURI = SpotifySource.parse(url: uri)
        #expect(parsedURI?.type == "track")
        #expect(parsedURI?.id == "4cOdK2wGLETKBW3PvgPWqT")
    }

    @Test func spotifyTokenDecoding() throws {
        let json = """
        {
            "clientId": "some_client_id",
            "accessToken": "BQBtest_access_token_12345",
            "accessTokenExpirationTimestampMs": 1732176000000,
            "isAnonymous": true
        }
        """.data(using: .utf8)!

        let token = try JSONDecoder().decode(SpotifyTokenResponse.self, from: json)
        #expect(token.accessToken == "BQBtest_access_token_12345")
        #expect(token.accessTokenExpirationTimestampMs == 1732176000000)
        #expect(token.isAnonymous == true)
    }

    @Test func spotifyTrackDecodingWithISRC() throws {
        let json = """
        {
            "id": "4cOdK2wGLETKBW3PvgPWqT",
            "name": "Never Gonna Give You Up",
            "duration_ms": 213573,
            "artists": [{"id": "0gxyHStUsqpMadRV0Di1Qt", "name": "Rick Astley"}],
            "album": {
                "id": "1m6vXq5Y7o11F9J247jW21",
                "name": "Whenever You Need Somebody",
                "images": [{"url": "https://i.scdn.co/image/ab67616d0000b2735755e164993798e0c9ef7d7a", "height": 640, "width": 640}]
            },
            "external_ids": {
                "isrc": "GBARL9300134"
            }
        }
        """.data(using: .utf8)!

        let trackResponse = try JSONDecoder().decode(SpotifyTrackResponse.self, from: json)
        #expect(trackResponse.id == "4cOdK2wGLETKBW3PvgPWqT")
        #expect(trackResponse.name == "Never Gonna Give You Up")
        #expect(trackResponse.external_ids?.isrc == "GBARL9300134")
        #expect(trackResponse.artists?.first?.name == "Rick Astley")
    }

    @Test func odesliDecoding() throws {
        let json = """
        {
            "entityUniqueId": "ITUNES_SONG::1440818817",
            "userCountry": "US",
            "pageUrl": "https://song.link/i/1440818817",
            "entitiesByUniqueId": {
                "ITUNES_SONG::1440818817": {
                    "id": "1440818817",
                    "type": "song",
                    "title": "Song Title",
                    "artistName": "Song Artist",
                    "thumbnailUrl": "https://example.com/thumb.jpg"
                }
            }
        }
        """.data(using: .utf8)!

        let odesli = try JSONDecoder().decode(OdesliResponse.self, from: json)
        #expect(odesli.entityUniqueId == "ITUNES_SONG::1440818817")
        #expect(odesli.entitiesByUniqueId?["ITUNES_SONG::1440818817"]?.title == "Song Title")
    }
}
