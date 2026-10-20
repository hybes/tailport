# tailport

`tailport` forwards ports from machines on your Tailscale network to `localhost`.
It includes a command for macOS and Windows, and a native SwiftUI app for macOS.

The command reads online peers from `tailscale status --json`, lets you choose
one, then opens one SSH connection containing all requested local forwards.

## Native macOS app

Build locally with Xcode's command-line tools (Swift 6 or newer):

```sh
make app
open dist/Tailport.app
```

Copy `dist/Tailport.app` to Applications to keep it installed. The app requires
macOS 14 or newer and Tailscale. It uses the system SSH client and your existing
SSH configuration; it does not need `jq`, `fzf`, or the `tp` command installed.

- Choose the Mac mini or another Tailscale machine. Its TCP listeners appear
  with their process names and refresh every ten seconds.
- Toggle a port to make it available at the same `localhost` port on this Mac.
  Click its address to open it in your browser.
- **All ports** applies to the full list of allowed ports. Showing ignored
  ports does not include them in this switch.
- **Exclusions** lets you edit ignored ports, ranges and process names.
  Right-click a port to add it to the exclusions.
- Apple sharing services, AirPlay, SSH and common system ports are ignored by
  default. AirPlay is excluded by process name, leaving ports 5000 and 7000
  available to development servers.
- Closing the window keeps forwarding active. Reopen it from the menu bar.
  Quitting the app closes its tunnels.

The selected machine and exclusions are remembered. Forwarding starts when
you toggle a port; it is not automatically restored on launch. Discovery uses
`lsof` on the remote Mac and shows listeners visible to your SSH user. No
remote agent or administrator access is required. Machines without macOS's
`/usr/sbin/lsof` are not supported by the app's discovery.

SSH authentication must already work without a password prompt. If the app
reports that SSH access needs attention, connect once in Terminal with
`ssh bh-mm` (or your selected machine), then refresh. Local port conflicts are
reported beside the affected port; the other forwards continue working.

## Install a release

### macOS (Darwin)

Download `tailport-0.1.0-darwin.tar.gz` and `SHA256SUMS`, then:

```sh
grep 'tailport-0.1.0-darwin.tar.gz$' SHA256SUMS | shasum -a 256 -c -
tar -xzf tailport-0.1.0-darwin.tar.gz
cd tailport-0.1.0-darwin
./install.sh
```

This installs `tailport` and its short alias `tp` into `~/.local/bin`. Set
`PREFIX` to use a different location.

### Windows

Download `tailport-0.1.0-windows.zip` and `SHA256SUMS`. In PowerShell:

```powershell
$expected = ((Select-String 'tailport-0.1.0-windows.zip$' SHA256SUMS).Line -split '\s+')[0]
$actual = (Get-FileHash .\tailport-0.1.0-windows.zip -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { throw 'Checksum verification failed' }

Expand-Archive .\tailport-0.1.0-windows.zip -DestinationPath .
cd .\tailport-0.1.0-windows
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
```

The Windows installer creates `tailport.cmd` and `tp.cmd` in the current
user's local application-data directory and adds that directory to the user
`PATH`. Open a new terminal after installation.

The release also provides standalone `tailport-0.1.0-darwin` and
`tailport-0.1.0-windows.ps1` scripts.

## Build from source

Download and extract `tailport-0.1.0-source.tar.gz`, or clone the repository.
The command implementations are ordinary Zsh and PowerShell. `make build`
stamps their version from `VERSION`. `make app` compiles the separate SwiftUI
app without third-party package dependencies.

```text
tailport/
├── macos/                        # native SwiftUI app and Swift tests
├── src/
│   ├── tailport.zsh               # Darwin implementation
│   └── tailport.ps1               # Windows implementation
├── scripts/
│   ├── build.zsh                  # builds both release scripts on Darwin
│   ├── build-app.zsh              # builds the native macOS app bundle
│   ├── build-windows.ps1          # builds the Windows script on Windows
│   ├── package.zsh                # creates archives and checksums
│   ├── install.sh                 # Darwin release installer
│   └── install.ps1                # Windows release installer
├── tests/
│   ├── tailport_test.zsh
│   └── tailport_windows_test.ps1
├── VERSION
├── Makefile
├── README.md
└── LICENSE
```

On Darwin:

```sh
make test
make install
```

On Windows:

```powershell
.\scripts\build-windows.ps1
.\tests\tailport_windows_test.ps1
.\scripts\install.ps1
```

GitHub Actions runs the command tests on both Darwin and Windows, plus the
Swift app tests on Darwin.

## Requirements

Darwin:

- macOS with `tailscale`, `ssh`, `zsh`, and `jq`
- `fzf` is optional; a numbered picker is used without it

Windows:

- Windows PowerShell 5.1 or newer
- Tailscale CLI and the Windows OpenSSH client

The destination must run an SSH server or Tailscale SSH.

## Create a release

On Darwin:

```sh
make release
```

For version `0.1.0`, this produces:

- `dist/tailport-0.1.0-darwin`
- `dist/tailport-0.1.0-darwin.tar.gz`
- `dist/tailport-0.1.0-windows.ps1`
- `dist/tailport-0.1.0-windows.zip`
- `dist/tailport-0.1.0-source.tar.gz`
- `dist/Tailport.app`
- `dist/tailport-0.1.0-macos.zip` (locally signed app, built for the current Mac's architecture)
- `dist/SHA256SUMS`

Change `VERSION` before a future release, commit the change, create a matching
tag such as `v0.2.0`, then attach the generated files to the release.

## Usage

Open the interactive machine picker and port prompt:

```text
tp
```

Provide the machine and ports directly:

```text
tp bh-mm 5173,3005
```

Map a different local port to a remote port:

```text
tp bh-mm 8080:3000
```

Specify an SSH user:

```text
tp --user ben bh-mm 5173,3005
```

Set `TAILPORT_USER` to make that user the default. Run `tp --help` for all
options. Keep the command running while using the forwarded ports; press
`Ctrl-C` to close every forward.

## Security

The command binds local listeners explicitly to `127.0.0.1`. The native app
binds both `127.0.0.1` and `::1`, and treats a conflict on either as a failure.
Forwarded ports are only available on the Mac running Tailport.

The command connects to remote services at `localhost`. The app uses
`localhost` for wildcard and loopback listeners, or the reported address for
listeners bound to a specific interface. The app requires an existing trusted
SSH host key; it does not automatically accept unknown or changed host keys.

## License

MIT
