# VibePod

A native music player for iPhone and iPad, built around synced lyrics.
It plays your own files and your iPhone's music library in an Apple Music–style Liquid Glass interface, with features Apple Music doesn't have.
100% Swift, no account, no ads.

## Killer features

- **Sing Along**: the vocals are separated from the music live, on device. Turn the voice down, sing over the instrumental and follow the lyrics as they go.
- **AutoMix**: DJ-style transitions between songs, timed on each song's tempo and structure. A plain crossfade is also available.
- **Music Videos**: the song's YouTube music video plays in place of the cover, in sync with your own audio file.
- **Song Merge**: join two songs into one, with a waveform editor to place the cut and pick the transition.
- **Music Haptics**: feel the beat through the Taptic Engine. VibePod has its own engine, or you can use iOS's.
- **AI Assistant**, by text or voice: "play something calm", "make a playlist for running", "what is this song about?". It can play, queue, build playlists and set a sleep timer.
- **Lyrics Sharing**: turn a few lines into an image or an animated video, with the cover's colors and the words lighting up as they're sung.
- **AirPods Gestures**: nod, shake or tilt your head to play or pause, skip, change the volume or shuffle. Works even with the iPhone locked.

## Everything else

- **Lyrics**: time-synced lyrics (LRC) found automatically, with on-device translation under each line and marks to cut a song's outro.
- **Animated Covers**: Apple Music's animated covers, when the album has one.
- **Games**: What Comes Next?, What Song Is That?, Who Sings This?, Music Tiles and Covers Snake, all played with your own library.
- **Stats**: listening history, top songs and artists, plus the music you play while working out (Apple Health).
- **Library**:
  - smart playlists (Autolists);
  - Spotify playlist import;
  - transfer of songs between your devices nearby.
- **Sound**: equalizer, AutoMix or crossfade, sleep timer.
- **Integrations**: Siri and Shortcuts actions, Home Screen widgets, Discord "Listening to" status.
- **Look**: Liquid Glass everywhere, custom accent color or Infused (colors from the playing song's cover), French and English.

## Requirements

- iOS 26+ (iPhone and iPad)
- Optional, for some features (stored in the Keychain, never in the app):
  - a Mistral API key for the assistant;
  - a YouTube Data API key for music videos.

## Build

Open `LRCplayer.xcodeproj` in Xcode and run the `LRCplayer` scheme.

The Discord Social SDK isn't included, because Discord licenses it. To build with the Discord status:
1. Download the SDK from the [Discord Developer Portal](https://discord.com/developers/docs/discord-social-sdk/getting-started).
2. Put `discord_partner_sdk.xcframework` in `Frameworks/`.

## Disclaimer

VibePod is not affiliated with, endorsed by, or approved by Apple, YouTube, Spotify or Discord.
