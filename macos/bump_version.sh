#!/bin/bash
# Semantic Versioning Helper for Echo Music CI/CD
# Determines the next version based on conventional commits or explicit bump strategy.
set -euo pipefail
cd "$(dirname "$0")"

BUMP_TYPE="${1:-auto}"

# Find the latest semantic tag matching vX.Y.Z
LATEST_TAG=$(git describe --tags --match "v[0-9]*.[0-9]*.[0-9]*" --abbrev=0 2>/dev/null || echo "")

if [[ -z "$LATEST_TAG" ]]; then
    # No tags exist yet; use baseline
    DEFAULT_VERSION="0.1.0"
    if [[ "$BUMP_TYPE" == "major" ]]; then
        NEXT_TAG="v1.0.0"
    elif [[ "$BUMP_TYPE" == "minor" ]]; then
        NEXT_TAG="v0.2.0"
    else
        NEXT_TAG="v${DEFAULT_VERSION}"
    fi
else
    # Parse version components from vX.Y.Z
    RAW_VERSION="${LATEST_TAG#v}"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$RAW_VERSION"

    # Default to patch
    DETERMINED_BUMP="patch"

    if [[ "$BUMP_TYPE" == "auto" ]]; then
        # Check commits since latest tag
        COMMIT_RANGE="${LATEST_TAG}..HEAD"
        if ! git rev-parse "$COMMIT_RANGE" >/dev/null 2>&1 || [[ "$(git rev-list --count "$COMMIT_RANGE" 2>/dev/null || echo 0)" -eq 0 ]]; then
            COMMITS=$(git log -1 --pretty=format:"%s %b")
        else
            COMMITS=$(git log "$COMMIT_RANGE" --pretty=format:"%s %b")
        fi

        if echo "$COMMITS" | grep -qE "(BREAKING CHANGE|^[a-z]+(\([a-zA-Z0-9_-]+\))?!:)"; then
            DETERMINED_BUMP="major"
        elif echo "$COMMITS" | grep -qE "^feat(\([a-zA-Z0-9_-]+\))?:"; then
            DETERMINED_BUMP="minor"
        else
            DETERMINED_BUMP="patch"
        fi
    else
        DETERMINED_BUMP="$BUMP_TYPE"
    fi

    case "$DETERMINED_BUMP" in
        major)
            MAJOR=$((MAJOR + 1))
            MINOR=0
            PATCH=0
            ;;
        minor)
            MINOR=$((MINOR + 1))
            PATCH=0
            ;;
        patch|*)
            PATCH=$((PATCH + 1))
            ;;
    esac

    NEXT_TAG="v${MAJOR}.${MINOR}.${PATCH}"
fi

echo "$NEXT_TAG"
