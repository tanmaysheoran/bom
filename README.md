# Universal BOM Generator

> One script. Every OS. Generate SBOM, CBOM, and HBOM in CycloneDX or SPDX format — with zero manual setup.

**Website:** [bom.lackofabetter.work](https://bom.lackofabetter.work)

---

## Overview

`generate_bom.sh` is a single unified bash script that produces three types of Bill of Materials from a single command. It runs without modification on macOS, Linux (Debian, Ubuntu, RHEL, Arch), and Windows via Git Bash or WSL. All dependencies are installed automatically. A temporary isolated Python venv is used for Python packages and cleaned up on exit — your system environment is never touched.

| BOM Type | What it covers |
|---|---|
| **SBOM** | Software packages and dependencies, with CVE vulnerability scan |
| **CBOM** | Cryptographic assets — certs, keys, crypto libraries, source references |
| **HBOM** | Physical hardware — CPU, RAM, disks, GPUs, NICs, firmware, peripherals |

---

## Quick Start

```bash
# Install and run in one command
curl -fsSL https://bom.lackofabetter.work/generate_bom.sh | bash

# Or download first
curl -fsSL https://bom.lackofabetter.work/generate_bom.sh -o generate_bom.sh
chmod +x generate_bom.sh
./generate_bom.sh
```

---

## Usage

```
./generate_bom.sh [TARGET_DIR] [MODE] [FORMAT]
```

| Argument | Options | Default |
|---|---|---|
| `TARGET_DIR` | Any path | `.` (current directory) |
| `MODE` | `sbom` · `cbom` · `hbom` · `all` | `all` |
| `FORMAT` | `cyclonedx-json` · `cyclonedx-xml` · `spdx-json` · `spdx-tag` | `cyclonedx-json` |

### Examples

```bash
# Full pipeline — all three BOMs, default format
./generate_bom.sh

# SBOM only, SPDX JSON output, specific directory
./generate_bom.sh /srv/app sbom spdx-json

# CBOM only, CycloneDX XML
./generate_bom.sh . cbom cyclonedx-xml

# HBOM only, SPDX tag-value
./generate_bom.sh . hbom spdx-tag

# Everything, SPDX JSON
./generate_bom.sh /my/project all spdx-json
```

---

## Output Formats

| Flag | Format | Extension | Notes |
|---|---|---|---|
| `cyclonedx-json` | CycloneDX 1.5 JSON | `.cdx.json` | Default. Compatible with IBM CBOM Analyzer, Dependency-Track |
| `cyclonedx-xml` | CycloneDX 1.5 XML | `.cdx.xml` | Legacy enterprise tools and XML pipelines |
| `spdx-json` | SPDX 2.3 JSON | `.spdx.json` | Government & DoD compliance. Includes `primaryPackagePurpose` |
| `spdx-tag` | SPDX 2.3 Tag-Value | `.spdx.tv` | Human-readable, diffable, good for source control |

For SBOM, Syft handles format output natively. For CBOM and HBOM, a CycloneDX JSON file is always produced first, then the built-in Python converter generates the requested format.

---

## Output Files

Every run creates a new timestamped folder — nothing is ever overwritten.

```
bom_output_20250312-143022/
├── sbom-20250312-143022.cdx.json          # Software BOM
├── sbom-vulnerabilities-20250312-143022.json  # Grype CVE report
├── cbom-20250312-143022.cdx.json          # Crypto BOM (always generated)
├── cbom-20250312-143022.cdx.xml           # Converted format (if requested)
├── hbom-20250312-143022.cdx.json          # Hardware BOM
└── hbom-20250312-143022.cdx.xml           # Converted format (if requested)
```

---

## How It Works

### 1 — OS & Package Manager Detection
Detects macOS, Linux, or Windows (Git Bash / WSL) via `uname -s` and automatically selects the right package manager: Homebrew, apt, dnf, pacman, or winget. Apple Silicon Homebrew paths are handled automatically.

### 2 — Self-Installing Dependencies
Checks for `syft`, `grype`, and `python3`. Missing tools are installed using the detected package manager or official install scripts. All Python packages go into an isolated venv at `/tmp/bom_venv_$$` so your system Python is untouched. A `trap cleanup EXIT` removes the venv and all temp files when the script finishes.

### 3 — SBOM via Syft + Grype
Runs `syft dir:TARGET -o FORMAT` against your target directory. The resulting SBOM is immediately passed to `grype sbom:FILE -o json` for a CVE vulnerability report.

### 4 — CBOM via Package Scan + File Discovery
Collects installed packages and filters for crypto libraries (`openssl`, `libssl`, `bcrypt`, `gnupg`, `libsodium`, `botan`, `mbedtls`, and more). Simultaneously scans the target directory for:

- **Certificate files** — `*.pem`, `*.crt`, `*.cer`, `*.der`, `*.p12`, `*.pfx`, `*.p7b`
- **Key files** — `*.key`, `*.pub`, `id_rsa`, `id_ed25519`, `id_ecdsa`, `id_dsa`
- **Token files** — `*.jwk`, `*.jwks`, `*.gpg`, `*.asc`
- **Java keystores** — `*.jks`, `*.keystore`
- **SSH files** — `known_hosts`, `authorized_keys`
- **Source references** — Python, JS, TS, Go, Java, C, C++ files mentioning `AES`, `RSA`, `ECDSA`, `SHA256`, `SHA512`, `Ed25519`, `openssl`, `bcrypt`, etc.

Output is CycloneDX 1.5 JSON, compatible with the [IBM CBOM Analyzer](https://www.zurich.ibm.com/cbom/).

### 5 — HBOM via Native OS APIs
Collects hardware inventory using the best available tool per platform:

| Component | macOS | Linux / WSL | Windows |
|---|---|---|---|
| CPU | `sysctl` | `/proc/cpuinfo` | `wmic cpu` |
| RAM | `system_profiler SPMemoryDataType` | `dmidecode -t memory` / `/proc/meminfo` | `wmic memorychip` |
| Disks | `system_profiler SPStorageDataType` | `lsblk` | `wmic diskdrive` |
| GPU | `system_profiler SPDisplaysDataType` | `lspci` | `wmic path win32_videocontroller` |
| NICs | `system_profiler SPNetworkDataType` | `ip -j link show` | `wmic nic` |
| Firmware | `system_profiler SPHardwareDataType` | `dmidecode -t bios` | `wmic bios` |
| USB | `system_profiler SPUSBDataType` | `lsusb` | — |

Components are serialised as CycloneDX `DEVICE` and `FIRMWARE` types.

### 6 — Format Conversion
CBOM and HBOM write CycloneDX JSON as the base output, then the built-in Python converter handles CycloneDX XML, SPDX 2.3 JSON, and SPDX 2.3 tag-value on request.

---

## Platform Notes

### macOS
- Homebrew is installed automatically if missing
- Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`) paths handled

### Linux
- Supports Debian/Ubuntu (`apt`), RHEL/Fedora (`dnf`), and Arch (`pacman`)
- `dmidecode` may require `sudo` for full memory and firmware data
- WSL is detected and treated as Linux

### Windows (Git Bash / WSL)
- Requires [Git for Windows](https://git-scm.com/download/win) or WSL
- Python 3 must be installed manually and added to PATH if not present: [python.org/downloads](https://python.org/downloads)
- `winget` is used for package discovery if available

---

## Dependencies

All installed automatically.

| Tool | Purpose | Install method |
|---|---|---|
| [Syft](https://github.com/anchore/syft) | SBOM generation | Homebrew / official install script |
| [Grype](https://github.com/anchore/grype) | CVE vulnerability scanning | Homebrew / official install script |
| Python 3 | CBOM + HBOM serialisation | OS package manager |
| [cyclonedx-python-lib](https://pypi.org/project/cyclonedx-python-lib/) | CycloneDX BOM output | pip (isolated venv) |

---

## GitHub Pages Deployment

This repo is hosted at [bom.lackofabetter.work](https://bom.lackofabetter.work) via GitHub Pages.

**To deploy your own fork:**

1. Enable GitHub Pages in **Settings → Pages → Branch: `main` / Folder: `/root`**
2. Add a `CNAME` file to the repo root containing your domain:
   ```
   bom.lackofabetter.work
   ```
3. In your DNS provider, add a `CNAME` record:
   ```
   bom  →  YOUR_USER.github.io
   ```
4. Update the script download URL in `index.html` to point to your raw file URL or domain.

---

## License

MIT — free to use, modify, and distribute.

---

## Made with Claude

This project was built entirely through a conversation with [Claude](https://claude.ai) (Anthropic). The prompt used to generate the script is published on the [website](https://bom.lackofabetter.work/#made-with-claude) so you can recreate or extend it yourself.
