#!/usr/bin/env bash
# Container integration test. Runs the container-safe modules in a clean
# Ubuntu image, twice, and asserts the second run is a no-op.
#
#   tests/container-smoke.sh [image]
set -euo pipefail

IMAGE="${1:-ubuntu:26.04}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Modules that declare container=yes in their meta.
mapfile -t SAFE < <(
    for d in "$REPO_ROOT"/modules/*/; do
        [[ -f ${d}meta ]] || continue
        if grep -qx 'container=yes' "${d}meta"; then
            basename "$d"
        fi
    done
)

if (( ${#SAFE[@]} == 0 )); then
    echo "No container-safe modules found." >&2
    exit 1
fi

ONLY_ARGS=()
for m in "${SAFE[@]}"; do
    ONLY_ARGS+=(--only "$m")
done

echo "Container-safe modules: ${SAFE[*]}"
echo "Image: $IMAGE"

docker run --rm -v "$REPO_ROOT:/repo:ro" "$IMAGE" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # sudo and a non-root user, because the engine refuses to run as root.
    apt-get install -y -qq sudo ca-certificates curl git > /dev/null
    useradd -m -s /bin/bash tester
    echo "tester ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tester
    # Passwordless sudo covers root-owned steps, but 10-shell also calls
    # plain `chsh` (not sudo) to make fish the login shell, and chsh
    # authenticates via the *user'"'"'s own* password through PAM, not sudo.
    # A freshly useradd-ed account has a locked password ("!" in shadow),
    # which PAM treats as a hard, un-skippable auth failure. A real user
    # account always has a usable password, so the container-only fix is to
    # relax PAM for chsh specifically (pam_permit), rather than feed a
    # password over stdin — piping stdin into the whole run would also leak
    # into other stdin-reading children further down the same module
    # (observed: the fisher installer picked up a piped literal as a
    # plugin name). Scoped to this disposable container only; never touches
    # how a real machine authenticates.
    sed -i "1i auth sufficient pam_permit.so" /etc/pam.d/chsh
    cp -r /repo /home/tester/config
    chown -R tester:tester /home/tester/config
    su tester -c "cd /home/tester/config && ./bootstrap.sh --yes '"${ONLY_ARGS[*]}"' 2>&1 | tee /tmp/run1.log"
    su tester -c "cd /home/tester/config && ./bootstrap.sh --yes '"${ONLY_ARGS[*]}"' 2>&1 | tee /tmp/run2.log"

    echo "--- idempotency check ---"
    # The second run must not report any failures.
    if grep -q "\[ERROR\]" /tmp/run2.log; then
        echo "FAIL: the second run logged errors" >&2
        grep "\[ERROR\]" /tmp/run2.log >&2
        exit 1
    fi
    # And it must report already-present state rather than redoing work.
    # Grepping only for the absence of errors is weak on its own — a second
    # run that silently did nothing at all would also pass that. This also
    # requires a positive signal: at least one line showing the engine
    # recognized existing state instead of re-doing the work (SSH key,
    # fisher, asdf, pyenv, uv, and rustup all log this way on a no-op rerun;
    # see modules/10-shell/setup.sh and modules/20-toolchains/setup.sh).
    already_count=$(grep -cE "already (installed|present)" /tmp/run2.log || true)
    if [[ $already_count -eq 0 ]]; then
        echo "FAIL: the second run did not report any already-present state" >&2
        exit 1
    fi
    echo "Second run reported $already_count already-installed/already-present line(s)."
    echo "PASS: second run was clean and reported existing state"
'
