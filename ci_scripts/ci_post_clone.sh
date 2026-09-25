#!/bin/sh
# Xcode Cloud runs this after cloning. The .xcodeproj is not committed; it is
# generated from project.yml by XcodeGen, so install XcodeGen and generate it
# before Xcode Cloud looks for Grokbox.xcodeproj.
set -eu

brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
