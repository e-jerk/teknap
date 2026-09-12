# TekNap 2

OpenNap / Napster client in Zig. Speaks classic Napster frames, TLS `naps/1`, and RFC 7194 `ircs-u`.

This is a new implementation. It is not the original TekNap C tree and does not ship that code. Version **2.0.0** is a major bump over TekNap 1.3g.

Requires Zig 0.16 and OpenSSL 3. [`zust`](https://github.com/e-jerk/zust) is fetched via `build.zig.zon`.

License: [UNLICENSE](UNLICENSE).

## Homebrew (macOS)

```bash
brew tap e-jerk/teknap
brew install teknap
teknap -v
teknap -n YourNick napster.barrettharber.com
```

Apple Silicon bottles are published on each `v*.*.*` release. The formula depends on `openssl@3`. Intel Macs should build from source (below) or use Docker.

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
docker pull ghcr.io/e-jerk/teknap:2.0.0

docker run --rm -it --network host \
  -e NAPNICK=YourNick \
  -e NAPPASS=secret \
  ghcr.io/e-jerk/teknap:latest -n YourNick napster.barrettharber.com
```

`-it` is required for the TUI. `--network host` lets TLS and peer transfers use the host network. On Docker Desktop, map nothing extra if you only chat; file transfers still need a reachable data port.

Connect and exit after login (no TTY needed):

```bash
docker run --rm --network host \
  ghcr.io/e-jerk/teknap:2.0.0 --once -n YourNick napster.barrettharber.com
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

Environment: `NAPNICK`, `NAPPASS`, `NAPSERVER`, `NAPTLS`, `NAPINSECURE`.

## Releases

Push a semver tag to build macOS archives and a GitHub Release:

```bash
git tag v2.0.1
git push origin v2.0.1
```

That updates `Formula/teknap.rb` bottle hashes and publishes `ghcr.io/e-jerk/teknap:2.0.1`.
