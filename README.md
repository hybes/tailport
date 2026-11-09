# tailport

`tailport` forwards ports from machines on your Tailscale network to `localhost`.
It includes a command for macOS and Windows, and a native SwiftUI app for macOS.

The command reads online peers from `tailscale status --json`, lets you choose
one, then opens one SSH connection containing all requested local forwards.

## Native macOS app

Download `tailport-0.3.0-macos.zip` from the
[latest release](https://github.com/hybes/tailport/releases/latest), open it
and drag `Tailport.app` to Applications. Release builds are signed with a
Developer ID and notarised by Apple, and run on Apple silicon and Intel Macs.

Or build locally with Xcode's command-line tools (Swift 6 or newer):

```sh
make app
open dist/Tailport.app
```

Copy `dist/Tailport.app` to Applications to keep it installed. The app requires
macOS 14 or newer and Tailscale. It uses the system SSH client and your existing
SSH configuration; it does not need `jq`, `fzf`, or the `tp` command installed.

- Choose the Mac mini or another Tailscale machine. Machines use their
  Tailscale names, as in Tailscale's own menu, and machines shared with you are
  grouped under their owner. TCP listeners appear with their process names and
  refresh every ten seconds.
- Toggle a port to make it available at the same `localhost` port on this Mac.
  Click its address to open it in your browser.
- **All ports** applies to the full list of allowed ports. Showing excluded
  ports does not include them in this switch.
- **Exclusions** lets you edit excluded ports, ranges and process names.
  Right-click a port to add it to the exclusions.
- Apple sharing services, AirPlay, SSH and common system ports are excluded by
  default. AirPlay is excluded by process name, leaving ports 5000 and 7000
  available to development servers.
- Closing the window keeps forwarding active. Reopen it from the menu bar.
  Quitting the app closes its tunnels.

### Devices on a machine's network

**Add device** (the + button) reaches a device on the selected machine's
network, such as its router, through the same SSH connection Tailport uses for
ports. Nothing needs installing or approving on that machine.

- **Scan network** lists the devices on that network and which common ports
  answer: web and admin pages, file sharing, printers, Plex, Jellyfin, Home
  Assistant, development servers such as 3000 and 5173, Minecraft (Java) and
  more. Click a port to forward it. The scan runs on the remote machine over
  SSH using `ping`, `nc` and its neighbour table, takes 5–10 seconds, and needs
  nothing installed. Only TCP is checked, so UDP services such as Minecraft
  Bedrock cannot be forwarded.
- Or enter the device's address and port, for example `192.168.1.254:443` for an
  EE or BT Smart Hub. Ports below 1024 open locally above 10000, so the hub
  opens at `https://localhost:10443`. Click the address to open it: web ports
  open in the browser, file sharing in Finder, screen sharing in Screen
  Sharing. For services such as Minecraft, connect to the address from the app.
  Expect a certificate warning: the hub's certificate is not for `localhost`.
- This works when the remote network uses the same addresses as the network
  you are on, which Tailscale routing cannot handle.
- Devices are remembered for each machine. Right-click one to remove it.
  **All ports** does not turn devices on or off; **Stop all forwarding** in the
  menu bar stops both.

### Route through a device

**Route traffic through** sends this Mac's traffic through another Tailscale
machine, so you can reach that machine's network while you are away. For
example, choose the Raspberry Pi at home to open your router's admin page or
reach other devices on your home network. The same choice is in the menu bar.

- The list shows online machines approved as Tailscale exit nodes. Machines
  that also share a subnet show it, for example `bh-pi-5 · 192.168.1.0/24`.
- Choosing a machine runs `tailscale set --exit-node=<machine>`. When the
  machine shares a subnet, Tailport also turns on Tailscale's
  `--accept-routes`, which stays on when routing is turned off.
- Choose **Off** to go back to your normal connection. Routing is a Tailscale
  setting, so it stays on after Tailport quits until you turn it off here or in
  Tailscale.
- Routing cannot reach a remote network that uses the same addresses as your
  current network, or as a subnet another machine shares, such as two home
  networks that both use `192.168.1.x`. Use **Add device** for those.
- To offer a machine, turn on "Run as exit node" on it (or run
  `tailscale set --advertise-exit-node` on Linux), then approve it in the
  Tailscale admin console. A Mac that runs as an exit node cannot use another
  one at the same time.

The selected machine and exclusions are remembered. Forwarding starts when
you toggle a port; it is not automatically restored on launch. Discovery uses
`lsof` on the remote machine and shows listeners visible to your SSH user. No
remote agent or administrator access is required. Linux machines need `lsof`
on the PATH; without root it only sees your SSH user's processes.

SSH authentication must already work without a password prompt. If the app
reports that SSH access needs attention, connect once in Terminal with
`ssh bh-mm` (or your selected machine), then refresh. Local port conflicts are
reported beside the affected port; the other forwards continue working.

### Updates

Tailport checks GitHub for a new release once a day. When one is out, a
banner in the window and an item in the menu bar offer to install it.
**Install and Relaunch** downloads the release, checks it against the
release's `SHA256SUMS` and checks that it is Tailport signed with the same
Developer ID, then replaces the app and opens the new one. Forwarding stops
while it relaunches.

- **Check for Updates…** in the Tailport menu checks now. Turn off **Check for
  Updates Automatically** there to stop the daily check.
- Tailport replaces itself where it is. If it can't write there, it says so
  and links to the release to download by hand.
- Builds made with `make app` use an ad-hoc signature, but still update to
  signed releases.

## Windows app

`windows/` contains a Windows version of the app with the same features:
Tailscale machine names, listening ports, devices on a machine's network
with network scan, routing through an exit node, exclusions and a tray icon.
It is built with .NET 10 and Avalonia, and ships as one self-contained
`Tailport.exe` for Windows 10 or 11 (x64 or ARM64). Nothing else needs
installing besides Tailscale and the OpenSSH Client, which Windows includes.

Build it from macOS, Linux or Windows with the .NET 10 SDK:

```sh
make windows-app        # dist/tailport-<version>-windows-app-{x64,arm64}.zip
make test-windows-app   # core tests, including a check that the network scan
                        # script and port list match the macOS app
make windows-screenshots  # renders every window off-screen to dist/windows-screenshots
```

GitHub Actions also builds `Tailport.exe` on Windows and attaches it to each
run as the `Tailport-windows-x64` artifact.

- Settings live in `%APPDATA%\Tailport\settings.json`. Set `TAILPORT_SETTINGS`
  to use a different file, and `TAILPORT_THEME=light` or `dark` to force an
  appearance.
- Closing the window keeps forwarding running in the tray. Quit from the tray
  icon's menu. Windows closes every SSH tunnel when Tailport exits, even if it
  crashes.
- As on macOS, SSH must already work without a password prompt: connect once
  in a terminal with `ssh <machine>` first.
- Tailport checks GitHub for a new release once a day and shows a banner when
  one is out. **Install and restart** downloads the zip for this PC's
  architecture, checks it against the release's `SHA256SUMS`, swaps in the new
  `Tailport.exe` and restarts. The previous exe is kept as `Tailport.exe.old`
  until the next launch. The tray menu's **Updates** submenu checks now or
  turns the daily check off. The exe is not code-signed, so the checksum and
  GitHub's HTTPS connection are the only checks. Builds without a release
  version, such as `dotnet run`, never update.

## Install a release

### macOS (Darwin)

Download `tailport-0.3.0-darwin.tar.gz` and `SHA256SUMS`, then:

```sh
grep 'tailport-0.3.0-darwin.tar.gz$' SHA256SUMS | shasum -a 256 -c -
tar -xzf tailport-0.3.0-darwin.tar.gz
cd tailport-0.3.0-darwin
./install.sh
```

This installs `tailport` and its short alias `tp` into `~/.local/bin`. Set
`PREFIX` to use a different location.

### Windows app

Download `tailport-0.3.0-windows-app-x64.zip` (or `-arm64` for ARM PCs) and
`SHA256SUMS`, check the zip as below, extract it and run `Tailport.exe`. It
needs Tailscale and the OpenSSH Client that Windows includes. The app is not
code-signed, so Windows SmartScreen asks you to confirm the first time
(**More info › Run anyway**).

### Windows command

Download `tailport-0.3.0-windows.zip` and `SHA256SUMS`. In PowerShell:

```powershell
$expected = ((Select-String 'tailport-0.3.0-windows.zip$' SHA256SUMS).Line -split '\s+')[0]
$actual = (Get-FileHash .\tailport-0.3.0-windows.zip -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { throw 'Checksum verification failed' }

Expand-Archive .\tailport-0.3.0-windows.zip -DestinationPath .
cd .\tailport-0.3.0-windows
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
```

The Windows installer creates `tailport.cmd` and `tp.cmd` in the current
user's local application-data directory and adds that directory to the user
`PATH`. Open a new terminal after installation.

The release also provides standalone `tailport-0.3.0-darwin` and
`tailport-0.3.0-windows.ps1` scripts.

## Build from source

Download and extract `tailport-0.3.0-source.tar.gz`, or clone the repository.
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

For version `0.3.0`, this produces:

- `dist/tailport-0.3.0-darwin`
- `dist/tailport-0.3.0-darwin.tar.gz`
- `dist/tailport-0.3.0-windows.ps1`
- `dist/tailport-0.3.0-windows.zip`
- `dist/tailport-0.3.0-source.tar.gz`
- `dist/Tailport.app`
- `dist/tailport-0.3.0-macos.zip` (universal app)
- `dist/tailport-0.3.0-windows-app-x64.zip` and `-arm64.zip` (when the .NET 10 SDK is installed)
- `dist/SHA256SUMS`

`make release` builds an ad-hoc signed, universal Mac app. Set
`TAILPORT_SIGN_IDENTITY` to sign with a Developer ID, and
`TAILPORT_NOTARY_PROFILE` to notarise and staple it.

### Publish a release

The apps update from the latest GitHub release, so publish with:

```sh
make publish NOTES=notes.md    # NOTES is optional; GitHub writes notes without it
```

This checks that `main` is clean and pushed and that the version's tag is new,
then signs the Mac app with the Developer ID Application certificate for team
`BBU4YNR4U3`, notarises and staples it, builds the Windows apps, verifies
`SHA256SUMS`, tags `v<VERSION>`, pushes the tag and creates the release with
every file in `dist/`. `scripts/publish.zsh --dry-run` does everything except
tag and publish.

It needs `gh` signed in, the .NET 10 SDK, the certificate in the login
keychain, and notarisation credentials. Store an App Store Connect API key once
as the `notary` profile, which any project on the Mac can use:

```sh
xcrun notarytool store-credentials notary \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEY ID>.p8 --key-id <KEY ID> --issuer <ISSUER ID>
```

Set `TAILPORT_NOTARY_PROFILE` to use another profile, or `TAILPORT_NOTARY_KEY_ID`
and `TAILPORT_NOTARY_ISSUER` to use the key file directly.

For each release, change `VERSION`, commit and push, then run `make publish`.

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
