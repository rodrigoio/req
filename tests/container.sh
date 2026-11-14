#!/usr/bin/env bash
# container.sh - runs the whole suite in a container, as a normal user, to check that req
# works on another distribution (T7.1, T7.2). Needs docker (or podman through DOCKER=podman).
#
#   tests/container.sh debian:12-slim
#   tests/container.sh quay.io/centos/centos:stream9
#   tests/container.sh registry.access.redhat.com/ubi9/ubi
#
# The repository is mounted read-only and copied inside, so nothing is written to it. The
# container gets 1 GB of memory (CONTAINER_MEMORY changes it). Prints the versions of the
# tools and a total of asserts, failures and skipped tests (a skip means a missing tool,
# so it fails too).

# shellcheck disable=SC2016  # the script below is for the shell inside the container
INNER='
set -e
if command -v apt-get >/dev/null; then
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends curl jq python3 vim-tiny make ca-certificates openssl >/dev/null 2>&1
else
    pm=$(command -v dnf || command -v yum)
    # curl is already there (curl-minimal on some images), so it is left alone
    "$pm" install -y -q --allowerasing jq python3 vim-minimal make findutils procps-ng diffutils openssl >/dev/null 2>&1
    command -v curl >/dev/null || "$pm" install -y -q --allowerasing curl >/dev/null 2>&1
fi
id tester >/dev/null 2>&1 || useradd -m tester
cp -R /src /home/tester/work && rm -rf /home/tester/work/.git && chown -R tester /home/tester/work
runuser -u tester -- bash -c '"'"'
cd ~/work
echo "bash $BASH_VERSION, $(curl -V | head -1 | cut -d" " -f1-2), $(jq --version), $(python3 -V), vi: $(command -v vi)"
bash -n bin/req lib/*.sh tests/*.sh && echo "syntax ok"
tests/run.sh 2>&1 | grep -E "asserts|FAIL|not ok|^  skip" | awk "/asserts/{s+=\$1; f+=\$3} /^  skip/{k++} /FAIL|not ok|^  skip/{print} END{print \"TOTAL\", s, \"asserts,\", f, \"failures,\", k+0, \"skipped\"; exit (f > 0 || k > 0 || s == 0)}"
'"'"'
'

main() {
    local root image=${1-} engine=${DOCKER:-docker}
    [[ -n $image ]] || { echo "usage: tests/container.sh <image>" >&2; return 2; }
    command -v "$engine" >/dev/null 2>&1 || { echo "$engine not found" >&2; return 2; }
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    "$engine" run --rm --memory "${CONTAINER_MEMORY:-1g}" -v "$root":/src:ro "$image" bash -c "$INNER"
}

main "$@"
