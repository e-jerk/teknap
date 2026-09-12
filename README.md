# TekNap 2

OpenNap / Napster client in Zig. Speaks classic Napster frames, TLS `naps/1`, and RFC 7194 `ircs-u`.

This is a new implementation. It is not the original TekNap C tree and does not ship that code. Version **2.1.0** follows the 2.0.0 major bump over TekNap 1.3g.

Requires Zig 0.16 and OpenSSL 3. [`zust`](https://github.com/e-jerk/zust) is fetched via `build.zig.zon`.

License: [UNLICENSE](UNLICENSE).

## Homebrew (macOS)

```bash
brew tap e-jerk/teknap
brew install teknap
teknap -v
teknap -n YourNick napster.barrettharber.com
```

Apple Silicon bottles are published on each `v*.*.*` release. The formula depends on `openssl@3` and `gnupg`. Intel Macs should build from source (below) or use Docker.

On macOS, TekNap uses your **default GnuPG secret key** (`~/.gnupg`) when it is Ed25519. No extra flags:

```bash
brew install gnupg
gpg --quick-generate-key "Your Name <you@example>" ed25519 default never
teknap -n YourNick
```

If the key is passphrase-protected, set `NAPGPG_PASSPHRASE` or export a hex seed (below). `NAPGPG=0` or `--no-gpg` turns this off.

To tap the main repo instead of `e-jerk/homebrew-teknap`:

```bash
brew tap e-jerk/teknap https://github.com/e-jerk/teknap
brew install teknap
```

## Docker (linux/amd64 and linux/arm64)

Images publish to GHCR on `main` and version tags:

`ghcr.io/e-jerk/teknap`

```bash
docker pull ghcr.io/e-jerk/teknap:latest
# or a release
docker pull ghcr.io/e-jerk/teknap:2.1.0

docker run --rm -it --network host \
  -e NAPNICK=YourNick \
  -e NAPPASS=secret \
  ghcr.io/e-jerk/teknap:latest -n YourNick napster.barrettharber.com
```

### GPG key via environment

Pass an armored OpenPGP **secret** (Ed25519) or a 64-character hex seed. The image includes `gnupg`.

```bash
# armored secret from your host keyring
docker run --rm -it --network host \
  -e NAPNICK=YourNick \
  -e NAPGPG="$(gpg --export-secret-keys --armor)" \
  -e NAPGPG_PASSPHRASE='your-key-passphrase' \
  ghcr.io/e-jerk/teknap:latest

# or a file
docker run --rm -it --network host \
  -e NAPNICK=YourNick \
  -e NAPGPG="$(cat ./secret.asc)" \
  ghcr.io/e-jerk/teknap:latest
```

A 32-byte Ed25519 seed (64 hex chars) needs no GnuPG and no passphrase:

```bash
docker run --rm -it --network host \
  -e NAPNICK=YourNick \
  -e NAPGPG="$(openssl rand -hex 32)" \
  ghcr.io/e-jerk/teknap:latest
```

### GPG key via mount

```bash
# Linux: share the host GnuPG homedir (read-write; gpg may update trustdb)
docker run --rm -it --network host \
  -v "$HOME/.gnupg:/gnupg" \
  -e GNUPGHOME=/gnupg \
  -e NAPNICK=YourNick \
  -e NAPGPG_PASSPHRASE='your-key-passphrase' \
  ghcr.io/e-jerk/teknap:latest

# or mount a single secret
docker run --rm -it --network host \
  -v "$PWD/secret.asc:/key.asc:ro" \
  -e NAPGPG=/key.asc \
  -e NAPNICK=YourNick \
  ghcr.io/e-jerk/teknap:latest
```

On Docker Desktop (macOS/Windows) the host `gpg-agent` socket does not work inside the container. Prefer `NAPGPG="$(gpg --export-secret-keys --armor)"` there.

`-it` is required for the TUI. `--network host` lets TLS and peer transfers use the host network. On Docker Desktop, map nothing extra if you only chat; file transfers still need a reachable data port.

Connect and exit after login (no TTY needed):

```bash
docker run --rm --network host \
  ghcr.io/e-jerk/teknap:2.1.0 --once -n YourNick napster.barrettharber.com
```

## Linux (from source)

```bash
# Debian / Ubuntu
sudo apt-get install -y libssl-dev curl xz-utils

# Zig 0.16
arch=$(uname -m)
curl -fsSL "https://ziglang.org/download/0.16.0/zig-${arch}-linux-0.16.0.tar.xz" | tar -xJ
export PATH="$PWD/zig-${arch}-linux-0.16.0:$PATH"

git clone https://github.com/e-jerk/teknap.git
cd teknap
zig build -Doptimize=ReleaseSafe
./zig-out/bin/teknap -n YourNick napster.barrettharber.com
```

Alpine:

```bash
apk add openssl-dev
zig build -Doptimize=ReleaseSafe -Dtarget=$(uname -m)-linux-musl -Dcpu=baseline
```

## Build locally

```bash
# macOS
brew install zig openssl@3
zig build
zig build test
./zig-out/bin/teknap --help
```

## Usage

```text
teknap [switches] [nickname] [server list]
  -n nickname     nickname (or NAPNICK)
  -p password     password (or NAPPASS)
  -T              TLS naps/1 (Napster frames, port 6697)
  -I              TLS ircs-u (IRC lines, port 6697)
  -k              skip TLS certificate verification
  -C              create the account
  -N              do not auto-connect
  -1, --once      connect, print the session log, and exit
  --gpg [spec]    GPG / Ed25519 key (default: system GnuPG secret)
  --gpg-file PATH armored secret, hex seed file, or GnuPG homedir
  --no-gpg        disable GPG
  -v              print the version
```

Server specs: `host`, `host:port`, `tls:host`, `naps:host`, `irc:host`, `https:host`, `plain:host:port`.

The directory order is TLS metaserver **8876**, then `https://host/meta` on **443**, then plaintext **8875**. The hub is **6697**.

```bash
teknap napster.barrettharber.com
teknap -T napster.barrettharber.com
teknap -I napster.barrettharber.com
teknap irc:napster.barrettharber.com
```

Environment: `NAPNICK`, `NAPPASS`, `NAPSERVER`, `NAPTLS`, `NAPINSECURE`, `NAPGPG`, `NAPGPG_PASSPHRASE`, `GNUPGHOME`.

`NAPGPG` may be `default` (system key), `0`/`off`, a 64/128-char hex seed, an armored OpenPGP secret, a file path, a GnuPG homedir, or a key id / email. OpenNap SASL `GPG` needs **Ed25519** (GnuPG algo 22/27). RSA keys are ignored.

## Releases

Push a semver tag to build macOS archives and a GitHub Release:

```bash
git tag v2.1.1
git push origin v2.1.1
```

That updates `Formula/teknap.rb` bottle hashes and publishes `ghcr.io/e-jerk/teknap:2.1.1`.
