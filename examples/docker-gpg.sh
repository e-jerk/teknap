#!/bin/sh
# Pass a host GnuPG secret into the TekNap image (Ed25519).
#   ./examples/docker-gpg.sh                 # default secret key, via env
#   ./examples/docker-gpg.sh /path/to/key.asc
#   NAPGPG_MOUNT=1 ./examples/docker-gpg.sh  # mount ~/.gnupg (Linux)

set -eu
IMAGE="${TEKNAP_IMAGE:-ghcr.io/e-jerk/teknap:latest}"
NICK="${NAPNICK:-TekNap}"

if [ "${NAPGPG_MOUNT:-}" = "1" ]; then
  exec docker run --rm -it --network host \
    -v "${HOME}/.gnupg:/gnupg" \
    -e GNUPGHOME=/gnupg \
    -e NAPNICK="$NICK" \
    ${NAPGPG_PASSPHRASE:+-e NAPGPG_PASSPHRASE="$NAPGPG_PASSPHRASE"} \
    "$IMAGE" "$@"
fi

if [ "${1:-}" != "" ] && [ -f "$1" ]; then
  KEY="$(cat "$1")"
  shift
else
  KEY="$(gpg --export-secret-keys --armor)"
fi

exec docker run --rm -it --network host \
  -e NAPNICK="$NICK" \
  -e NAPGPG="$KEY" \
  ${NAPGPG_PASSPHRASE:+-e NAPGPG_PASSPHRASE="$NAPGPG_PASSPHRASE"} \
  "$IMAGE" "$@"
