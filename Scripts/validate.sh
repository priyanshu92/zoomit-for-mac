#!/usr/bin/env bash
set -euo pipefail

swift run ValidationRunner
swift build
