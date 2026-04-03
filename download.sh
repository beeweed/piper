#!/usr/bin/env bash
###############################################################################
# download.sh — Download ALL Piper TTS voice models
#
# This script:
#   1. Creates the voices/ directory if it doesn't exist
#   2. Downloads voices.json from HuggingFace (if missing)
#   3. Parses voices.json and downloads every .onnx + .onnx.json file
#   4. Supports resuming (skips files that already exist and are non-empty)
#   5. Uses parallel downloads (configurable with MAX_PARALLEL)
#
# Usage:
#   chmod +x download.sh
#   ./download.sh              # download all voices
#   ./download.sh --list       # list all available voices without downloading
#   ./download.sh --lang en    # download only voices for a specific language family
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICES_DIR="${SCRIPT_DIR}/voices"
VOICES_JSON="${VOICES_DIR}/voices.json"
HF_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"

# Max parallel downloads (adjust based on your bandwidth)
MAX_PARALLEL="${MAX_PARALLEL:-8}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Counters
TOTAL_FILES=0
DOWNLOADED=0
SKIPPED=0
FAILED=0

###############################################################################
# Helper functions
###############################################################################
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
log_header()  { echo -e "\n${BOLD}═══════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}\n"; }

check_deps() {
    local missing=()
    for cmd in curl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_fail "Missing required commands: ${missing[*]}"
        log_info "Install them and try again."
        exit 1
    fi
}

###############################################################################
# Step 1: Ensure voices.json exists
###############################################################################
ensure_voices_json() {
    mkdir -p "${VOICES_DIR}"

    if [[ -f "${VOICES_JSON}" && -s "${VOICES_JSON}" ]]; then
        log_ok "voices.json already exists ($(du -h "${VOICES_JSON}" | cut -f1))"
    else
        log_info "Downloading voices.json from HuggingFace..."
        curl -sL "${HF_BASE}/voices.json" -o "${VOICES_JSON}"
        if [[ -f "${VOICES_JSON}" && -s "${VOICES_JSON}" ]]; then
            log_ok "voices.json downloaded successfully ($(du -h "${VOICES_JSON}" | cut -f1))"
        else
            log_fail "Failed to download voices.json"
            exit 1
        fi
    fi
}

###############################################################################
# Step 2: Parse voices.json and build download list
###############################################################################
build_download_list() {
    local lang_filter="${1:-}"

    python3 -c "
import json, sys

with open('${VOICES_JSON}') as f:
    voices = json.load(f)

lang_filter = '${lang_filter}'.strip()

for voice_key, voice_info in sorted(voices.items()):
    lang_family = voice_info['language'].get('family', '')
    lang_code = voice_info['language'].get('code', '')

    # Apply language filter if specified
    if lang_filter:
        if lang_filter != lang_family and not lang_code.startswith(lang_filter):
            continue

    for file_path in voice_info['files']:
        if file_path.endswith('.onnx') or file_path.endswith('.onnx.json'):
            print(file_path)
"
}

###############################################################################
# Step 3: Download a single file
###############################################################################
download_file() {
    local file_path="$1"
    local dest="${VOICES_DIR}/${file_path}"
    local url="${HF_BASE}/${file_path}"

    # Skip if already downloaded
    if [[ -f "${dest}" && -s "${dest}" ]]; then
        log_skip "${file_path} (already exists)"
        return 0
    fi

    # Create parent directory
    mkdir -p "$(dirname "${dest}")"

    # Download
    if curl -sL --fail --retry 3 --retry-delay 2 "${url}" -o "${dest}" 2>/dev/null; then
        if [[ -s "${dest}" ]]; then
            log_ok "${file_path} ($(du -h "${dest}" | cut -f1))"
            return 0
        else
            rm -f "${dest}"
            log_fail "${file_path} (empty file)"
            return 1
        fi
    else
        rm -f "${dest}"
        log_fail "${file_path} (download error)"
        return 1
    fi
}

export -f download_file log_ok log_skip log_fail
export VOICES_DIR HF_BASE RED GREEN YELLOW NC

###############################################################################
# Step 4: List voices (--list mode)
###############################################################################
list_voices() {
    local lang_filter="${1:-}"

    python3 - "${VOICES_JSON}" "${lang_filter}" << 'PYEOF'
import json, sys

voices_json = sys.argv[1]
lang_filter_val = sys.argv[2].strip() if len(sys.argv) > 2 else ""

with open(voices_json) as f:
    voices = json.load(f)

count = 0
hdr = f"{'Voice Key':<45} {'Language':<20} {'Quality':<10} {'Speakers':<10}"
print(hdr)
print("─" * 90)

for key in sorted(voices.keys()):
    v = voices[key]
    lang_family = v["language"].get("family", "")
    lang_code = v["language"].get("code", "")
    lang_name = v["language"].get("name_english", "Unknown")
    quality = v.get("quality", "?")
    speakers = v.get("num_speakers", 1)

    if lang_filter_val and lang_filter_val != lang_family and not lang_code.startswith(lang_filter_val):
        continue

    count += 1
    print(f"{key:<45} {lang_name:<20} {quality:<10} {speakers:<10}")

print(f"\nTotal: {count} voices")
PYEOF
}

###############################################################################
# Main
###############################################################################
main() {
    local mode="download"
    local lang_filter=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list|-l)
                mode="list"
                shift
                ;;
            --lang)
                lang_filter="$2"
                shift 2
                ;;
            --parallel|-p)
                MAX_PARALLEL="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --list, -l           List all available voices without downloading"
                echo "  --lang LANG          Filter by language family (e.g., en, es, fr, de, zh)"
                echo "  --parallel, -p NUM   Max parallel downloads (default: 8)"
                echo "  --help, -h           Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                   # Download ALL voices"
                echo "  $0 --list            # List all voices"
                echo "  $0 --lang en         # Download only English voices"
                echo "  $0 --lang es --list  # List only Spanish voices"
                echo "  $0 --parallel 16     # Download with 16 parallel workers"
                exit 0
                ;;
            *)
                log_fail "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    log_header "Piper TTS Voice Downloader"
    check_deps
    ensure_voices_json

    if [[ "${mode}" == "list" ]]; then
        list_voices "${lang_filter}"
        exit 0
    fi

    # Build download list
    log_info "Building download list..."
    mapfile -t FILES < <(build_download_list "${lang_filter}")
    TOTAL_FILES=${#FILES[@]}

    if [[ ${TOTAL_FILES} -eq 0 ]]; then
        log_info "No files to download."
        exit 0
    fi

    log_info "Found ${TOTAL_FILES} files to download"
    log_info "Using ${MAX_PARALLEL} parallel workers"
    if [[ -n "${lang_filter}" ]]; then
        log_info "Language filter: ${lang_filter}"
    fi
    echo ""

    # Download using xargs for parallelism (or sequential fallback)
    if command -v xargs &>/dev/null; then
        printf '%s\n' "${FILES[@]}" | xargs -P "${MAX_PARALLEL}" -I {} bash -c 'download_file "$@"' _ {}
    else
        for file_path in "${FILES[@]}"; do
            download_file "${file_path}"
        done
    fi

    # Final summary
    echo ""
    log_header "Download Complete"

    # Count results
    local total_downloaded=0
    local total_skipped=0
    local total_missing=0
    for file_path in "${FILES[@]}"; do
        local dest="${VOICES_DIR}/${file_path}"
        if [[ -f "${dest}" && -s "${dest}" ]]; then
            total_downloaded=$((total_downloaded + 1))
        else
            total_missing=$((total_missing + 1))
        fi
    done

    log_info "Total files: ${TOTAL_FILES}"
    log_ok   "Successfully available: ${total_downloaded}"
    if [[ ${total_missing} -gt 0 ]]; then
        log_fail "Missing/failed: ${total_missing}"
        log_info "Re-run this script to retry failed downloads."
    else
        log_ok "All voice models downloaded successfully!"
    fi

    # Show disk usage
    echo ""
    log_info "Disk usage: $(du -sh "${VOICES_DIR}" | cut -f1) in ${VOICES_DIR}"
}

main "$@"