#!/usr/bin/env bash
# =============================================================================
# Universal BOM Generator — SBOM · CBOM · HBOM
# Supports : macOS · Linux (Debian/Ubuntu/RHEL/Arch) · Windows (Git Bash/WSL)
#
# Output formats:
#   CycloneDX JSON   (cyclonedx-json)  ← default
#   CycloneDX XML    (cyclonedx-xml)
#   SPDX JSON        (spdx-json)
#   SPDX Tag-Value   (spdx-tag)
#
# Usage:
#   ./generate_bom.sh [TARGET_DIR] [MODE] [FORMAT]
#
#   TARGET_DIR — directory to scan           (default: .)
#   MODE       — sbom|cbom|hbom|all          (default: all)
#   FORMAT     — cyclonedx-json|cyclonedx-xml|spdx-json|spdx-tag
#                                            (default: cyclonedx-json)
#
# Examples:
#   ./generate_bom.sh . all cyclonedx-json
#   ./generate_bom.sh /srv/app sbom spdx-json
#   ./generate_bom.sh . hbom cyclonedx-xml
#   ./generate_bom.sh . cbom spdx-tag
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/bom-generator/main/generate_bom.sh | bash
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[•]${RESET} $*"; }
success() { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✘]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }

# ── Arguments ─────────────────────────────────────────────────────────────────
TARGET_DIR="${1:-.}"
MODE="${2:-all}"               # sbom | cbom | hbom | all
FORMAT="${3:-cyclonedx-json}"  # cyclonedx-json | cyclonedx-xml | spdx-json | spdx-tag

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${TARGET_DIR}/bom_output_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

# Validate FORMAT
case "$FORMAT" in
    cyclonedx-json|cyclonedx-xml|spdx-json|spdx-tag) ;;
    *) error "Unknown format '$FORMAT'. Choose: cyclonedx-json | cyclonedx-xml | spdx-json | spdx-tag" ;;
esac

# Derive file extension from format
ext_for_format() {
    case "$1" in
        cyclonedx-json) echo "cdx.json"  ;;
        cyclonedx-xml)  echo "cdx.xml"   ;;
        spdx-json)      echo "spdx.json" ;;
        spdx-tag)       echo "spdx.tv"   ;;
    esac
}
FILE_EXT="$(ext_for_format "$FORMAT")"

# ── OS Detection ──────────────────────────────────────────────────────────────
OS=""
detect_os() {
    case "$(uname -s)" in
        Darwin*)  OS="macos" ;;
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                OS="wsl"
            else
                OS="linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)  OS="windows_git_bash" ;;
        *) error "Unsupported OS: $(uname -s). Use macOS, Linux, or Windows (Git Bash/WSL)." ;;
    esac
    success "Detected OS: $OS"
}

# ── Package manager helpers ───────────────────────────────────────────────────
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_homebrew() {
    if ! cmd_exists brew; then
        info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
}

install_pkg_macos()  { ensure_homebrew; brew install "$1"; }
install_pkg_apt()    { sudo apt-get update -qq && sudo apt-get install -y "$1"; }
install_pkg_dnf()    { sudo dnf install -y "$1"; }
install_pkg_pacman() { sudo pacman -Sy --noconfirm "$1"; }

install_linux_pkg() {
    local pkg="$1"
    if   cmd_exists apt-get;  then install_pkg_apt    "$pkg"
    elif cmd_exists dnf;      then install_pkg_dnf    "$pkg"
    elif cmd_exists pacman;   then install_pkg_pacman "$pkg"
    else error "No supported Linux package manager found. Install '$pkg' manually."; fi
}

# ── Python + pip ──────────────────────────────────────────────────────────────
ensure_python() {
    if ! cmd_exists python3; then
        info "python3 not found — installing..."
        case "$OS" in
            macos)            install_pkg_macos python ;;
            linux|wsl)        install_linux_pkg python3 ;;
            windows_git_bash) error "Python3 not found. Install from https://python.org/downloads/ and check 'Add to PATH'." ;;
        esac
    fi
    success "python3: $(python3 --version)"

    if ! cmd_exists pip3 && ! python3 -m pip --version >/dev/null 2>&1; then
        info "pip not found — bootstrapping via get-pip.py..."
        curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        python3 /tmp/get-pip.py --quiet
    fi
    success "pip ready"
}

PY_VENV_DIR="/tmp/bom_venv_$$"
PY_VENV_CREATED=0

ensure_venv() {
    if [[ "$PY_VENV_CREATED" -eq 0 ]]; then
        info "Creating isolated Python venv at $PY_VENV_DIR ..."
        python3 -m venv "$PY_VENV_DIR"
        PY_VENV_CREATED=1
        success "Python venv ready"
    fi
    # Override python3 to use the venv for all subsequent calls
    export PATH="$PY_VENV_DIR/bin:$PATH"
}

ensure_py_pkg() {
    # ensure_py_pkg <python_import_name> <pip_package_name>
    local import_name="$1" pip_pkg="$2"
    ensure_venv
    if ! python3 -c "import ${import_name}" 2>/dev/null; then
        info "Installing Python package: ${pip_pkg}..."
        python3 -m pip install --upgrade "${pip_pkg}" --quiet
    fi
    success "Python pkg ready: ${pip_pkg}"
}

cleanup() {
    if [[ "$PY_VENV_CREATED" -eq 1 ]] && [[ -d "$PY_VENV_DIR" ]]; then
        info "Cleaning up temporary Python venv ($PY_VENV_DIR)..."
        rm -rf "$PY_VENV_DIR"
        success "Cleanup complete — venv removed"
    fi
    # Remove any leftover tmp files created by this run
    rm -f "/tmp/bom_packages_${TIMESTAMP}.txt" \
          "/tmp/bom_crypto_${TIMESTAMP}.txt"   \
          "/tmp/bom_hw_${TIMESTAMP}.json"      2>/dev/null || true
}

# ── Syft ──────────────────────────────────────────────────────────────────────
ensure_syft() {
    if cmd_exists syft; then success "syft: $(syft --version)"; return; fi
    info "Installing Syft..."
    case "$OS" in
        macos)
            install_pkg_macos syft ;;
        linux|wsl)
            curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
              | sh -s -- -b /usr/local/bin ;;
        windows_git_bash)
            curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
              | sh -s -- -b "$HOME/.local/bin"
            export PATH="$HOME/.local/bin:$PATH" ;;
    esac
    success "syft installed"
}

# ── Grype ─────────────────────────────────────────────────────────────────────
ensure_grype() {
    if cmd_exists grype; then success "grype: $(grype --version)"; return; fi
    info "Installing Grype..."
    case "$OS" in
        macos)
            install_pkg_macos grype ;;
        linux|wsl)
            curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
              | sh -s -- -b /usr/local/bin ;;
        windows_git_bash)
            curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
              | sh -s -- -b "$HOME/.local/bin"
            export PATH="$HOME/.local/bin:$PATH" ;;
    esac
    success "grype installed"
}

# ── Syft format flag mapper ───────────────────────────────────────────────────
# Syft's own format string differs slightly from our canonical names
syft_format_flag() {
    case "$FORMAT" in
        cyclonedx-json) echo "cyclonedx-json"  ;;
        cyclonedx-xml)  echo "cyclonedx-xml"   ;;
        spdx-json)      echo "spdx-json"        ;;
        spdx-tag)       echo "spdx-tag-value"   ;;
    esac
}

# ── Collect installed OS packages (shared by CBOM + HBOM) ────────────────────
collect_packages() {
    local tmpfile="$1"
    info "Collecting installed system packages..."
    case "$OS" in
        macos)
            if cmd_exists brew; then
                brew list --versions > "$tmpfile"
                success "Collected Homebrew packages"
            else
                system_profiler SPApplicationsDataType -json > "$tmpfile"
                success "Collected macOS apps via system_profiler"
            fi
            ;;
        linux|wsl)
            if   cmd_exists dpkg-query; then dpkg-query -W -f='${Package} ${Version}\n' > "$tmpfile"
            elif cmd_exists rpm;        then rpm -qa --queryformat '%{NAME} %{VERSION}\n' > "$tmpfile"
            elif cmd_exists pacman;     then pacman -Q > "$tmpfile"
            else warn "No supported package manager found — component list may be empty."; touch "$tmpfile"
            fi
            success "Collected Linux system packages"
            ;;
        windows_git_bash)
            if cmd_exists winget; then
                winget list --accept-source-agreements 2>/dev/null | tail -n +3 > "$tmpfile" || touch "$tmpfile"
                success "Collected Windows packages via winget"
            else
                warn "winget not available — component list will be empty."
                touch "$tmpfile"
            fi
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# FORMAT CONVERTER
# Converts a CycloneDX JSON BOM → CycloneDX XML | SPDX JSON | SPDX tag-value
# ══════════════════════════════════════════════════════════════════════════════
convert_format() {
    local src="$1" dst="$2" fmt="$3"
    [[ "$fmt" == "cyclonedx-json" ]] && return  # nothing to convert
    info "Converting output to format: $fmt → $dst"
    ensure_python
    ensure_py_pkg "cyclonedx" "cyclonedx-python-lib"

    python3 - "$src" "$dst" "$fmt" <<'PYEOF'
import sys, json, uuid, datetime

src_file = sys.argv[1]
dst_file = sys.argv[2]
fmt      = sys.argv[3]

try:
    with open(src_file) as f:
        raw = json.load(f)

    components = raw.get("components", [])

    # ── Re-hydrate a minimal Bom so we can use the CycloneDX serialisers ─────
    from cyclonedx.model.bom import Bom
    import cyclonedx.model.component as cmod

    bom = Bom()
    for comp in components:
        ctype_str = comp.get("type", "library").upper()
        try:
            ctype = cmod.ComponentType[ctype_str]
        except KeyError:
            ctype = cmod.ComponentType.LIBRARY
        bom.components.add(cmod.Component(
            name=comp.get("name", "unknown"),
            version=comp.get("version", ""),
            type=ctype
        ))

    # ── CycloneDX XML ─────────────────────────────────────────────────────────
    if fmt == "cyclonedx-xml":
        from cyclonedx.output.xml import XmlV1Dot5
        out = XmlV1Dot5(bom)
        with open(dst_file, "w") as f:
            f.write(out.output_as_string())

    # ── SPDX JSON 2.3 ────────────────────────────────────────────────────────
    elif fmt == "spdx-json":
        spdx = {
            "SPDXID": "SPDXRef-DOCUMENT",
            "spdxVersion": "SPDX-2.3",
            "creationInfo": {
                "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "creators": ["Tool: Universal BOM Generator v2.0"]
            },
            "name": "BOM",
            "dataLicense": "CC0-1.0",
            "documentNamespace": f"https://example.org/bom/{uuid.uuid4()}",
            "packages": []
        }
        for idx, comp in enumerate(components, start=1):
            spdx["packages"].append({
                "SPDXID": f"SPDXRef-{idx}",
                "name": comp.get("name", "unknown"),
                "versionInfo": comp.get("version", "NOASSERTION") or "NOASSERTION",
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "primaryPackagePurpose": comp.get("type", "LIBRARY").upper()
            })
        with open(dst_file, "w") as f:
            json.dump(spdx, f, indent=2)

    # ── SPDX Tag-Value 2.3 ───────────────────────────────────────────────────
    elif fmt == "spdx-tag":
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        lines = [
            "SPDXVersion: SPDX-2.3",
            "DataLicense: CC0-1.0",
            "SPDXID: SPDXRef-DOCUMENT",
            "DocumentName: BOM",
            f"DocumentNamespace: https://example.org/bom/{uuid.uuid4()}",
            "Creator: Tool: Universal BOM Generator v2.0",
            f"Created: {now}",
            ""
        ]
        for idx, comp in enumerate(components, start=1):
            lines += [
                f"PackageName: {comp.get('name','unknown')}",
                f"SPDXID: SPDXRef-{idx}",
                f"PackageVersion: {comp.get('version','NOASSERTION') or 'NOASSERTION'}",
                "PackageDownloadLocation: NOASSERTION",
                "FilesAnalyzed: false",
                f"PrimaryPackagePurpose: {comp.get('type','LIBRARY').upper()}",
                ""
            ]
        with open(dst_file, "w") as f:
            f.write("\n".join(lines))

    print(f"[✔] Format conversion complete → {dst_file}")

except Exception as e:
    import traceback; traceback.print_exc()
    print(f"[✘] Format conversion failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    success "Converted → $dst"
}

# ══════════════════════════════════════════════════════════════════════════════
# SBOM — Software Bill of Materials
#   Tool   : Syft (scan) + Grype (vuln scan)
#   Formats: cyclonedx-json | cyclonedx-xml | spdx-json | spdx-tag
# ══════════════════════════════════════════════════════════════════════════════
generate_sbom() {
    header "📦 SBOM — Software Bill of Materials"
    ensure_syft
    ensure_grype

    local sbom_file="$OUTPUT_DIR/sbom-${TIMESTAMP}.${FILE_EXT}"
    local vuln_file="$OUTPUT_DIR/sbom-vulnerabilities-${TIMESTAMP}.json"

    info "Format  : $FORMAT"
    info "Scanning: $TARGET_DIR"

    # Syft handles all four of our target formats natively
    syft dir:"$TARGET_DIR" -o "$(syft_format_flag)" > "$sbom_file"
    success "SBOM saved → $sbom_file"

    # Grype accepts CycloneDX and SPDX SBOMs; output is always JSON
    info "Running vulnerability scan with Grype..."
    grype sbom:"$sbom_file" -o json > "$vuln_file"
    success "Vulnerability report → $vuln_file"
}

# ══════════════════════════════════════════════════════════════════════════════
# CBOM — Cryptography Bill of Materials
#   Scans  : installed packages (crypto libs) + filesystem crypto assets
#   Formats: cyclonedx-json (IBM Analyzer) | cyclonedx-xml | spdx-json | spdx-tag
#   Compat : https://www.zurich.ibm.com/cbom/
# ══════════════════════════════════════════════════════════════════════════════
generate_cbom() {
    header "🔐 CBOM — Cryptography Bill of Materials"
    ensure_python
    ensure_py_pkg "cyclonedx" "cyclonedx-python-lib"

    local pkg_tmp="/tmp/bom_packages_${TIMESTAMP}.txt"
    collect_packages "$pkg_tmp"

    # Scan the target directory for cryptographic file patterns and source references
    local crypto_tmp="/tmp/bom_crypto_${TIMESTAMP}.txt"
    info "Scanning $TARGET_DIR for cryptographic assets..."
    {
        # TLS/SSL certificates
        find "$TARGET_DIR" -type f \( \
            -name "*.pem" -o -name "*.crt" -o -name "*.cer" -o -name "*.der" \
            -o -name "*.p12" -o -name "*.pfx" -o -name "*.p7b" \
        \) 2>/dev/null || true

        # Private / public keys
        find "$TARGET_DIR" -type f \( \
            -name "*.key" -o -name "*.pub" \
            -o -name "id_rsa" -o -name "id_ed25519" -o -name "id_ecdsa" -o -name "id_dsa" \
        \) 2>/dev/null || true

        # JWK / JWKS
        find "$TARGET_DIR" -type f \( -name "*.jwk" -o -name "*.jwks" \) 2>/dev/null || true

        # GPG keyrings / armour
        find "$TARGET_DIR" -type f \( -name "*.gpg" -o -name "*.asc" \) 2>/dev/null || true

        # Java keystores
        find "$TARGET_DIR" -type f \( -name "*.jks" -o -name "*.keystore" \) 2>/dev/null || true

        # SSH known_hosts / authorized_keys
        find "$TARGET_DIR" -type f \( -name "known_hosts" -o -name "authorized_keys" \) 2>/dev/null || true

        # Source files referencing common crypto primitives
        grep -rl \
            --include="*.py" --include="*.js" --include="*.ts" \
            --include="*.go" --include="*.java" --include="*.c" --include="*.cpp" \
            -e "openssl" -e "cryptography" -e "hashlib" -e "bcrypt" \
            -e "AES" -e "RSA" -e "ECDSA" -e "SHA256" -e "SHA512" -e "Ed25519" \
            "$TARGET_DIR" 2>/dev/null || true
    } | sort -u > "$crypto_tmp"

    # Always produce CycloneDX JSON first (IBM Analyzer base + conversion source)
    local cbom_cdx_json="$OUTPUT_DIR/cbom-${TIMESTAMP}.cdx.json"
    local cbom_out="$OUTPUT_DIR/cbom-${TIMESTAMP}.${FILE_EXT}"

    python3 - "$pkg_tmp" "$crypto_tmp" "$cbom_cdx_json" "$TARGET_DIR" <<'PYEOF'
import sys, json, datetime, os, re

pkg_file    = sys.argv[1]
crypto_file = sys.argv[2]
out_file    = sys.argv[3]
target_dir  = sys.argv[4]

try:
    from cyclonedx.model.bom import Bom
    from cyclonedx.model.component import Component, ComponentType, OrganizationalEntity
    from cyclonedx.output.json import JsonV1Dot5

    bom = Bom()

    # ── Metadata ──────────────────────────────────────────────────────────────
    hostname = os.uname().nodename if hasattr(os, "uname") else "localhost"
    root = Component(
        name="System Cryptographic Environment",
        version="1.0.0",
        type=ComponentType.APPLICATION,
        supplier=OrganizationalEntity(name=hostname)
    )
    bom.metadata.component = root
    bom.metadata.timestamp  = datetime.datetime.now(datetime.timezone.utc)
    bom.metadata.tools = [
        Component(
            name="Universal BOM Generator",
            version="2.0.0",
            type=ComponentType.APPLICATION,
            supplier=OrganizationalEntity(name="generate_bom.sh")
        )
    ]

    # ── Crypto library patterns for source file scanning ──────────────────────
    CRYPTO_LIBS = {
        r"openssl":      ("openssl",      "Cryptographic library"),
        r"cryptography": ("cryptography", "Python crypto library"),
        r"hashlib":      ("hashlib",      "Python hashing module"),
        r"bcrypt":       ("bcrypt",       "Password hashing library"),
        r"\bAES\b":      ("AES",          "Symmetric cipher"),
        r"\bRSA\b":      ("RSA",          "Asymmetric cipher"),
        r"\bECDSA\b":    ("ECDSA",        "Elliptic-curve signing"),
        r"\bSHA256\b":   ("SHA-256",      "Hash function"),
        r"\bSHA512\b":   ("SHA-512",      "Hash function"),
        r"\bEd25519\b":  ("Ed25519",      "EdDSA signing scheme"),
    }

    # Packages that are crypto-relevant
    CRYPTO_PKG_PATTERN = re.compile(
        r"(openssl|libssl|libcrypto|gnutls|nss|botan|mbedtls|wolfssl|"
        r"cryptography|bcrypt|gpgme|gnupg|libgcrypt|libnacl|sodium|"
        r"bouncy.castle|keytool|pkcs|tls|ssl|x509)", re.I
    )

    added = set()

    def safe_add(name, version, ctype):
        key = (name.strip().lower(), version)
        if key not in added and name.strip():
            added.add(key)
            bom.components.add(Component(
                name=name.strip(), version=version or "N/A", type=ctype
            ))

    # ── Parse installed packages → keep crypto-relevant ones ─────────────────
    with open(pkg_file) as f:
        first = f.readline().strip(); f.seek(0)
        if first.startswith("{"):
            data = json.load(f)
            apps = data.get("_items") or data.get("SPApplicationsDataType") or []
            packages = [(a.get("_name",""), a.get("version","")) for a in apps]
        else:
            packages = []
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:   packages.append((parts[0], parts[1]))
                elif len(parts) == 1: packages.append((parts[0], "unknown"))

    for name, version in packages:
        if CRYPTO_PKG_PATTERN.search(name):
            safe_add(name, version, ComponentType.LIBRARY)

    # ── Parse crypto asset files ──────────────────────────────────────────────
    CERT_EXTS = {".pem",".crt",".cer",".der",".p12",".pfx",".p7b"}
    KEY_EXTS  = {".key",".pub"}
    KEY_NAMES = {"id_rsa","id_ed25519","id_ecdsa","id_dsa","known_hosts","authorized_keys"}
    JWK_EXTS  = {".jwk",".jwks"}
    GPG_EXTS  = {".gpg",".asc"}
    JKS_EXTS  = {".jks",".keystore"}

    with open(crypto_file) as f:
        for line in f:
            path = line.strip()
            if not path or not os.path.exists(path): continue
            fname = os.path.basename(path)
            ext   = os.path.splitext(fname)[1].lower()

            if ext in CERT_EXTS:
                safe_add(fname, "N/A", ComponentType.FILE)
            elif ext in KEY_EXTS or fname in KEY_NAMES:
                safe_add(fname, "N/A", ComponentType.FILE)
            elif ext in JWK_EXTS:
                safe_add(fname, "N/A", ComponentType.FILE)
            elif ext in GPG_EXTS:
                safe_add(fname, "N/A", ComponentType.FILE)
            elif ext in JKS_EXTS:
                safe_add(fname, "N/A", ComponentType.FILE)
            else:
                # Source file — scan for crypto library references
                try:
                    with open(path, errors="ignore") as src:
                        content = src.read(16384)
                    for pattern, (lib_name, _) in CRYPTO_LIBS.items():
                        if re.search(pattern, content, re.I):
                            safe_add(lib_name, "detected", ComponentType.LIBRARY)
                except OSError:
                    pass

    # ── Serialise ─────────────────────────────────────────────────────────────
    output = JsonV1Dot5(bom)
    with open(out_file, "w") as f:
        f.write(output.output_as_string())

    print(f"[✔] CBOM (CycloneDX JSON) saved → {out_file}")
    print(f"    Crypto components found: {len(list(bom.components))}")

except Exception as e:
    import traceback; traceback.print_exc()
    print(f"[✘] CBOM generation failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    success "CBOM (CycloneDX JSON) → $cbom_cdx_json"

    # Convert to requested format if needed
    if [[ "$FORMAT" != "cyclonedx-json" ]]; then
        convert_format "$cbom_cdx_json" "$cbom_out" "$FORMAT"
        success "CBOM ($FORMAT) → $cbom_out"
    fi

    info "Upload CycloneDX JSON to IBM CBOM Analyzer: https://www.zurich.ibm.com/cbom/"
}

# ══════════════════════════════════════════════════════════════════════════════
# HBOM — Hardware Bill of Materials
#   Collects: CPU · RAM · Disks · GPUs · NICs · Firmware · USB peripherals
#   Formats : cyclonedx-json | cyclonedx-xml | spdx-json | spdx-tag
# ══════════════════════════════════════════════════════════════════════════════
generate_hbom() {
    header "🖥  HBOM — Hardware Bill of Materials"
    ensure_python
    ensure_py_pkg "cyclonedx" "cyclonedx-python-lib"

    local hw_tmp="/tmp/bom_hardware_${TIMESTAMP}.json"
    info "Collecting hardware inventory..."

    # ── Per-OS hardware data collection ──────────────────────────────────────
    case "$OS" in
        macos)
            python3 - "$hw_tmp" <<'HWPY_MACOS'
import subprocess, json, re, sys

def run(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return ""

hw = {"cpu":[], "memory":[], "disk":[], "gpu":[], "nic":[], "firmware":[], "peripheral":[]}

# CPU
sysctl = run(["sysctl", "-a"])
cpu_brand   = re.search(r"machdep\.cpu\.brand_string:\s*(.+)", sysctl)
cpu_cores   = re.search(r"hw\.physicalcpu:\s*(\d+)", sysctl)
cpu_threads = re.search(r"hw\.logicalcpu:\s*(\d+)", sysctl)
hw["cpu"].append({
    "name":    cpu_brand.group(1).strip() if cpu_brand else "Unknown CPU",
    "cores":   cpu_cores.group(1)  if cpu_cores   else "?",
    "threads": cpu_threads.group(1) if cpu_threads else "?"
})

# Memory
mem_raw = run(["system_profiler", "SPMemoryDataType", "-json"])
try:
    mem_data = json.loads(mem_raw).get("SPMemoryDataType", [])
    for slot in mem_data:
        hw["memory"].append({
            "slot": slot.get("_name",""), "size": slot.get("dimm_size",""),
            "type": slot.get("dimm_type",""), "speed": slot.get("dimm_speed",""),
            "manufacturer": slot.get("dimm_manufacturer","")
        })
except Exception:
    total = re.search(r"hw\.memsize:\s*(\d+)", sysctl)
    if total:
        hw["memory"].append({"slot":"Total","size":f"{round(int(total.group(1))/1024**3,1)} GB","type":"","speed":"","manufacturer":""})

# Disks
disk_raw = run(["system_profiler", "SPStorageDataType", "-json"])
try:
    for d in json.loads(disk_raw).get("SPStorageDataType", []):
        hw["disk"].append({
            "name": d.get("_name",""), "size": str(d.get("size_in_bytes","")),
            "medium": d.get("spstorage_medium_type",""), "protocol": d.get("spstorage_protocol_type","")
        })
except Exception:
    pass

# GPU
gpu_raw = run(["system_profiler", "SPDisplaysDataType", "-json"])
try:
    for g in json.loads(gpu_raw).get("SPDisplaysDataType", []):
        hw["gpu"].append({
            "name": g.get("sppci_model",""), "vram": g.get("sppci_vram",""),
            "vendor": g.get("sppci_vendor","")
        })
except Exception:
    pass

# NICs
nic_raw = run(["system_profiler", "SPNetworkDataType", "-json"])
try:
    for n in json.loads(nic_raw).get("SPNetworkDataType", []):
        hw["nic"].append({
            "name": n.get("_name",""), "type": n.get("type",""),
            "mac": n.get("Ethernet",{}).get("MAC Address","")
        })
except Exception:
    pass

# Firmware / System info
fw_raw = run(["system_profiler", "SPHardwareDataType", "-json"])
try:
    fw = json.loads(fw_raw).get("SPHardwareDataType", [{}])[0]
    hw["firmware"].append({
        "model":    fw.get("machine_model",""),
        "serial":   fw.get("serial_number",""),
        "os_ver":   fw.get("os_loader_version",""),
        "boot_rom": fw.get("SMC_version_system","")
    })
except Exception:
    pass

# USB Peripherals
usb_raw = run(["system_profiler", "SPUSBDataType", "-json"])
try:
    def walk_usb(items):
        for item in items:
            hw["peripheral"].append({
                "name": item.get("_name",""), "vendor_id": item.get("vendor_id",""),
                "product_id": item.get("product_id",""), "type": "USB"
            })
            if "_items" in item:
                walk_usb(item["_items"])
    walk_usb(json.loads(usb_raw).get("SPUSBDataType", []))
except Exception:
    pass

with open(sys.argv[1], "w") as f:
    json.dump(hw, f, indent=2)
print("[✔] macOS hardware data collected")
HWPY_MACOS
            ;;

        linux|wsl)
            python3 - "$hw_tmp" <<'HWPY_LINUX'
import subprocess, json, re, sys, os

def run(cmd):
    try:
        return subprocess.check_output(
            cmd, text=True, stderr=subprocess.DEVNULL,
            shell=isinstance(cmd, str)
        )
    except Exception:
        return ""

hw = {"cpu":[], "memory":[], "disk":[], "gpu":[], "nic":[], "firmware":[], "peripheral":[]}

# CPU
cpuinfo = run("cat /proc/cpuinfo")
model   = re.search(r"model name\s*:\s*(.+)", cpuinfo)
cores   = run("nproc --all").strip()
hw["cpu"].append({
    "name": model.group(1).strip() if model else "Unknown CPU",
    "cores": cores, "threads": cores
})

# Memory
dmidecode_path = "/usr/sbin/dmidecode"
if os.path.exists(dmidecode_path):
    dmi = run(["sudo", "dmidecode", "-t", "memory"])
    for block in dmi.split("Memory Device"):
        size = re.search(r"Size:\s*(.+)", block)
        if size and "No Module" not in size.group(1):
            hw["memory"].append({
                "slot": "",
                "size": size.group(1).strip(),
                "type": (re.search(r"\tType:\s*(.+)", block) or type('',(),{'group':lambda s,x:''})()).group(1) if re.search(r"\tType:\s*(.+)", block) else "",
                "speed": (re.search(r"Speed:\s*(.+)", block) or type('',(),{'group':lambda s,x:''})()).group(1) if re.search(r"Speed:\s*(.+)", block) else "",
                "manufacturer": (re.search(r"Manufacturer:\s*(.+)", block) or type('',(),{'group':lambda s,x:''})()).group(1) if re.search(r"Manufacturer:\s*(.+)", block) else ""
            })
else:
    meminfo = run("cat /proc/meminfo")
    total   = re.search(r"MemTotal:\s+(\d+)", meminfo)
    if total:
        hw["memory"].append({"slot":"Total","size":f"{round(int(total.group(1))/1024**2,1)} GB","type":"","speed":"","manufacturer":""})

# Disks
lsblk = run(["lsblk","-J","-o","NAME,SIZE,TYPE,MODEL,TRAN"])
try:
    for d in json.loads(lsblk).get("blockdevices",[]):
        if d.get("type") == "disk":
            hw["disk"].append({
                "name": d.get("model") or d.get("name",""),
                "size": d.get("size",""), "medium": d.get("tran",""), "protocol": d.get("tran","")
            })
except Exception:
    pass

# GPU
for line in run(["lspci"]).splitlines():
    if re.search(r"VGA|3D|Display|GPU", line, re.I):
        hw["gpu"].append({"name": line.split(":",2)[-1].strip(), "vram":"", "vendor":""})

# NICs
ip_out = run(["ip","-j","link","show"])
try:
    for l in json.loads(ip_out):
        if l.get("link_type") != "loopback":
            hw["nic"].append({"name":l.get("ifname",""),"type":l.get("link_type",""),"mac":l.get("address","")})
except Exception:
    pass

# Firmware
if os.path.exists(dmidecode_path):
    dmi_sys = run(["sudo","dmidecode","-t","system"])
    dmi_bio = run(["sudo","dmidecode","-t","bios"])
    hw["firmware"].append({
        "model":    (re.search(r"Product Name:\s*(.+)", dmi_sys) or type('',(),{'group':lambda s,x:''})()).group(1),
        "serial":   "",
        "os_ver":   "",
        "boot_rom": (re.search(r"Version:\s*(.+)", dmi_bio) or type('',(),{'group':lambda s,x:''})()).group(1)
    })

# USB peripherals
for line in run(["lsusb"]).splitlines():
    m = re.match(r"Bus \d+ Device \d+: ID ([\da-f:]+) (.+)", line)
    if m:
        hw["peripheral"].append({"name":m.group(2).strip(),"vendor_id":m.group(1),"product_id":"","type":"USB"})

with open(sys.argv[1], "w") as f:
    json.dump(hw, f, indent=2)
print("[✔] Linux hardware data collected")
HWPY_LINUX
            ;;

        windows_git_bash)
            python3 - "$hw_tmp" <<'HWPY_WIN'
import subprocess, json, sys

def wmic(cls, fields=None):
    try:
        cmd = ["wmic", cls, "get", "/format:list"]
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        result = {}
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=",1)
                result[k.strip()] = v.strip()
        return result
    except Exception:
        return {}

hw = {"cpu":[], "memory":[], "disk":[], "gpu":[], "nic":[], "firmware":[], "peripheral":[]}

cpu = wmic("cpu")
hw["cpu"].append({"name":cpu.get("Name","Unknown"),"cores":cpu.get("NumberOfCores","?"),"threads":cpu.get("NumberOfLogicalProcessors","?")})

mem = wmic("memorychip")
hw["memory"].append({"slot":"","size":mem.get("Capacity","?"),"type":mem.get("MemoryType",""),"speed":mem.get("Speed",""),"manufacturer":mem.get("Manufacturer","")})

disk = wmic("diskdrive")
hw["disk"].append({"name":disk.get("Model",""),"size":disk.get("Size",""),"medium":disk.get("MediaType",""),"protocol":disk.get("InterfaceType","")})

gpu = wmic("path win32_videocontroller")
hw["gpu"].append({"name":gpu.get("Caption",""),"vram":gpu.get("AdapterRAM",""),"vendor":gpu.get("AdapterCompatibility","")})

nic = wmic("nic where PhysicalAdapter=TRUE")
hw["nic"].append({"name":nic.get("Name",""),"type":nic.get("AdapterType",""),"mac":nic.get("MACAddress","")})

bios = wmic("bios")
hw["firmware"].append({"model":bios.get("Manufacturer",""),"serial":bios.get("SerialNumber",""),"os_ver":"","boot_rom":bios.get("Version","")})

with open(sys.argv[1], "w") as f:
    json.dump(hw, f, indent=2)
print("[✔] Windows hardware data collected")
HWPY_WIN
            ;;
    esac

    # ── Convert hardware JSON → CycloneDX BOM ─────────────────────────────────
    local hbom_cdx_json="$OUTPUT_DIR/hbom-${TIMESTAMP}.cdx.json"
    local hbom_out="$OUTPUT_DIR/hbom-${TIMESTAMP}.${FILE_EXT}"

    python3 - "$hw_tmp" "$hbom_cdx_json" <<'PYEOF'
import sys, json, datetime, os

hw_file  = sys.argv[1]
out_file = sys.argv[2]

try:
    from cyclonedx.model.bom import Bom
    from cyclonedx.model.component import Component, ComponentType, OrganizationalEntity
    from cyclonedx.output.json import JsonV1Dot5

    with open(hw_file) as f:
        hw = json.load(f)

    bom      = Bom()
    hostname = os.uname().nodename if hasattr(os, "uname") else "localhost"

    bom.metadata.component = Component(
        name=f"Hardware Inventory — {hostname}",
        version="1.0.0",
        type=ComponentType.DEVICE,
        supplier=OrganizationalEntity(name=hostname)
    )
    bom.metadata.timestamp = datetime.datetime.now(datetime.timezone.utc)
    bom.metadata.tools = [
        Component(
            name="Universal BOM Generator", version="2.0.0",
            type=ComponentType.APPLICATION,
            supplier=OrganizationalEntity(name="generate_bom.sh")
        )
    ]

    added = set()
    def safe_add(name, version, ctype):
        key = name.strip().lower()
        if key and key not in added:
            added.add(key)
            bom.components.add(Component(
                name=name.strip(),
                version=(version or "N/A").strip(),
                type=ctype
            ))

    for cpu in hw.get("cpu", []):
        safe_add(cpu.get("name","Unknown CPU"),
                 f"cores={cpu.get('cores','?')} threads={cpu.get('threads','?')}",
                 ComponentType.DEVICE)

    for mem in hw.get("memory", []):
        label = " ".join(filter(None,[mem.get("size",""),mem.get("type",""),mem.get("speed",""),mem.get("manufacturer","")]))
        safe_add(f"RAM — {label}".strip(), "", ComponentType.DEVICE)

    for disk in hw.get("disk", []):
        name = disk.get("name","") or "Unknown Disk"
        safe_add(f"Disk — {name} [{disk.get('medium','')}]", disk.get("size",""), ComponentType.DEVICE)

    for gpu in hw.get("gpu", []):
        safe_add(f"GPU — {gpu.get('name','')}".strip(), gpu.get("vram",""), ComponentType.DEVICE)

    for nic in hw.get("nic", []):
        safe_add(f"NIC — {nic.get('name','')}".strip(), nic.get("mac",""), ComponentType.DEVICE)

    for fw in hw.get("firmware", []):
        label = f"{fw.get('model','')} {fw.get('boot_rom','')}".strip()
        if label:
            safe_add(f"Firmware — {label}", fw.get("serial",""), ComponentType.FIRMWARE)

    for p in hw.get("peripheral", []):
        name = p.get("name","") or "Unknown Peripheral"
        safe_add(f"Peripheral — {name} [{p.get('type','')}]", p.get("vendor_id",""), ComponentType.DEVICE)

    output = JsonV1Dot5(bom)
    with open(out_file, "w") as f:
        f.write(output.output_as_string())

    print(f"[✔] HBOM (CycloneDX JSON) saved → {out_file}")
    print(f"    Hardware components: {len(list(bom.components))}")

except Exception as e:
    import traceback; traceback.print_exc()
    print(f"[✘] HBOM generation failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    success "HBOM (CycloneDX JSON) → $hbom_cdx_json"

    # Convert to requested format if needed
    if [[ "$FORMAT" != "cyclonedx-json" ]]; then
        convert_format "$hbom_cdx_json" "$hbom_out" "$FORMAT"
        success "HBOM ($FORMAT) → $hbom_out"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}┌──────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${GREEN}│              BOM Generation Complete ✅               │${RESET}"
    echo -e "${BOLD}${GREEN}└──────────────────────────────────────────────────────┘${RESET}"
    echo -e "  ${BOLD}Output directory :${RESET} $OUTPUT_DIR"
    echo -e "  ${BOLD}Format           :${RESET} $FORMAT"
    echo ""
    echo -e "  ${BOLD}Files generated:${RESET}"
    ls -1 "$OUTPUT_DIR" | while read -r f; do
        size=$(du -sh "$OUTPUT_DIR/$f" 2>/dev/null | cut -f1)
        echo -e "    ${CYAN}→${RESET} $f  ${YELLOW}(${size})${RESET}"
    done
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
main() {
    trap cleanup EXIT
    header "🛡  Universal BOM Generator v2.0"
    echo -e "  ${BOLD}Target :${RESET} $TARGET_DIR"
    echo -e "  ${BOLD}Mode   :${RESET} $MODE"
    echo -e "  ${BOLD}Format :${RESET} $FORMAT"
    echo -e "  ${BOLD}Output :${RESET} $OUTPUT_DIR"
    echo ""

    detect_os

    case "$MODE" in
        sbom) generate_sbom ;;
        cbom) generate_cbom ;;
        hbom) generate_hbom ;;
        all)  generate_sbom; generate_cbom; generate_hbom ;;
        *)    error "Unknown mode '$MODE'. Use: sbom | cbom | hbom | all" ;;
    esac

    print_summary
    cleanup
}

main
