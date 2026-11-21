# Sources

## Overview
Contains the Swift package target source implementations for Echo Music on macOS, separating external C library bridging from the primary application subsystem.

## Subdirectories & Boundaries
- [CZlib](./CZlib/README.md): System library target exposing the macOS system `zlib` compression library to the Swift runtime via Clang module mapping.
- [EchoMusic](./EchoMusic/README.md): Core native SwiftUI application, AVPlayer audio engine, YouTube Music catalog integration, local library persistence, and real-time Listen Together room synchronization.
