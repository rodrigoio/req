#!/usr/bin/env bash
# version.sh - the single source of the req version (semantic versioning, MAJOR.MINOR.PATCH).
# Sourced by bin/req; the build process reads REQ_VERSION from here.

# shellcheck disable=SC2034  # read by bin/req
REQ_VERSION="0.2.0"
