# tailport

`tailport` is a small macOS and Windows command for interactively forwarding
ports from a machine on your Tailscale network to `localhost`.

It reads online peers from `tailscale status --json`, lets you choose one, then
opens one SSH connection containing all requested local forwards.

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
The implementations are ordinary, inspectable Zsh and PowerShell. The build
only stamps the version from `VERSION`; it does not compile native code.

```text
tailport/
├── src/
│   ├── tailport.zsh               # Darwin implementation
│   └── tailport.ps1               # Windows implementation
├── scripts/
│   ├── build.zsh                  # builds both release scripts on Darwin
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

GitHub Actions runs the native test suite on both Darwin and Windows.

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

Local listeners bind explicitly to `127.0.0.1`, so forwarded ports are only
available on the machine running `tailport`. SSH connects to remote services at
`localhost`, allowing the destination to select its available IPv4 or IPv6
loopback listener.

## License

MIT
