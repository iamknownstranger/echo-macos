# Echo Music for macOS

Play YouTube Music, import local audio, and host or join a Listen Together room with Echo on Android. The native SwiftUI app runs on Apple silicon Macs with macOS 14 or later.

## Build and run

Install Xcode or the Command Line Tools with Swift 6. From the root of this repository, run the following commands.

```sh
./macos/test.sh
./macos/build.sh
open "macos/build/Echo Music.app"
```

The build also writes `macos/build/Echo-Music-arm64.zip` and signs the app locally with an ad-hoc signature.

## Pair with Android

Open **Listen Together** on the Mac and **Together** on Android. Select the same room server on both devices. Create a room on either device, enter its eight-character code on the other, and approve the listener on the host. Play, pause, change tracks, or seek from the host. [Mac guide](macos/README.md)

## Source and roadmap

This standalone checkout contains the Mac source, tests, license, and artwork from Echo commit `f5f317f`. Cross-platform changes are developed in the Echo repository, which also contains the matching Android client. [Echo source commit](https://github.com/iamknownstranger/echo/commit/f5f317faa894b73e747cb49411cb63854ba491a0) · [Provider and feature roadmap](macos/ROADMAP.md) · [License](LICENSE)
