#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build
swift run TestRunner
