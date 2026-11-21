# CZlib

## Overview
System library target for Swift Package Manager exposing the macOS system `zlib` compression library to the Swift runtime.

## Interface
- `module CZlib [system]` [module.modulemap:CZlib]
- `header "shim.h"` [module.modulemap:shim.h]
- `link "z"` [module.modulemap:z]
- `export *` [module.modulemap:export]
- `#include <zlib.h>` [shim.h:zlib.h]

## Invariants
- None

## Side Effects
- None

## Verification
- Run: `swift test --package-path ../..` (or `./macos/test.sh` from repository root)
