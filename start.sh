#!/usr/bin/env bash
###############################################################################
# start.sh — Start the Piper TTS Web Application with all dependencies
#
# This script:
#   1. Detects the OS and Python version
#   2. Creates a virtual environment (if it doesn't exist)
#   3. Installs all Python dependencies (piper-tts, fastapi, uvicorn)
#   4. Downloads voices.json (if missing)
#   5. Optionally downloads voice models (at least one English voice for demo)
#   6. Starts the FastAPI server on the configured port
#
# Usage:
#   chmod +x start.sh
#   ./start.sh                     # Start with defaults (port 8080)
#   ./start.sh --port 9000         # Start on a custom port
#   ./start.sh --host 127.0.0.1    # Bind to localhost only
#   ./start.sh --no-download       # Skip downloading any voices
#   ./start.sh --download-all      # Download ALL voices before starting
#   ./start.sh --dev               # Start with auto-reload (dev mode)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICES_DIR="${SCRIPT_DIR}/voices"
VOICES_JSON="${VOICES_DIR}/voices.json"
VENV_DIR="${SCRIPT_DIR}/.venv"
HF_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"

# Defaults
HOST="0.0.0.0"
PORT="8080"
NO_DOWNLOAD=false
DOWNLOAD_ALL=false
DEV_MODE=false
DEFAULT_VOICE="en_US-lessac-medium"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

###############################################################################
# Helper functions
###############################################################################
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
log_step()    { echo -e "\n${BOLD}▸ $*${NC}"; }
log_header()  {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║          🔊  Piper TTS Studio — Launcher             ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

cleanup() {
    log_info "Shutting down Piper TTS server..."
    kill "${SERVER_PID:-0}" 2>/dev/null || true
    exit 0
}

###############################################################################
# Parse arguments
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|-p)
                PORT="$2"
                shift 2
                ;;
            --host|-H)
                HOST="$2"
                shift 2
                ;;
            --no-download)
                NO_DOWNLOAD=true
                shift
                ;;
            --download-all)
                DOWNLOAD_ALL=true
                shift
                ;;
            --dev|-d)
                DEV_MODE=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --port, -p PORT       Server port (default: 8080)"
                echo "  --host, -H HOST       Server host (default: 0.0.0.0)"
                echo "  --no-download         Skip downloading any voice models"
                echo "  --download-all        Download ALL voice models before starting"
                echo "  --dev, -d             Enable auto-reload for development"
                echo "  --help, -h            Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                    # Start normally on port 8080"
                echo "  $0 --port 9000        # Use port 9000"
                echo "  $0 --download-all     # Download all voices, then start"
                echo "  $0 --dev              # Dev mode with auto-reload"
                exit 0
                ;;
            *)
                log_fail "Unknown option: $1 (use --help for usage)"
                exit 1
                ;;
        esac
    done
}

###############################################################################
# Step 1: Check system requirements
###############################################################################
check_system() {
    log_step "Checking system requirements"

    # OS info
    local os_name="Unknown"
    if [[ -f /etc/os-release ]]; then
        os_name=$(grep ^PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    elif [[ "$(uname)" == "Darwin" ]]; then
        os_name="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
    fi
    log_info "OS: ${os_name}"
    log_info "Architecture: $(uname -m)"

    # Check for Python 3
    if command -v python3 &>/dev/null; then
        local py_version
        py_version=$(python3 --version 2>&1)
        log_ok "Python: ${py_version}"
    else
        log_fail "Python 3 is required but not found!"
        log_info "Install Python 3.9+ from https://www.python.org/downloads/"
        exit 1
    fi

    # Check Python version is >= 3.9
    local py_minor
    py_minor=$(python3 -c "import sys; print(sys.version_info.minor)")
    if [[ "${py_minor}" -lt 9 ]]; then
        log_fail "Python 3.9+ is required (found 3.${py_minor})"
        exit 1
    fi

    # Check for pip
    if ! python3 -m pip --version &>/dev/null; then
        log_fail "pip is required but not found!"
        log_info "Install pip: python3 -m ensurepip --upgrade"
        exit 1
    fi
    log_ok "pip: $(python3 -m pip --version 2>&1 | head -1)"

    # Check for curl
    if ! command -v curl &>/dev/null; then
        log_fail "curl is required but not found!"
        log_info "Install curl: sudo apt install curl (Debian/Ubuntu) or brew install curl (macOS)"
        exit 1
    fi
    log_ok "curl: available"
}

###############################################################################
# Step 2: Set up virtual environment
###############################################################################
setup_venv() {
    log_step "Setting up Python virtual environment"

    if [[ -d "${VENV_DIR}" && -f "${VENV_DIR}/bin/activate" ]]; then
        log_ok "Virtual environment already exists at ${VENV_DIR}"
    else
        log_info "Creating virtual environment at ${VENV_DIR}..."
        python3 -m venv "${VENV_DIR}"
        log_ok "Virtual environment created"
    fi

    # Activate
    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate"
    log_ok "Activated virtual environment"
    log_info "Python binary: $(which python)"
}

###############################################################################
# Step 3: Install dependencies
###############################################################################
install_deps() {
    log_step "Installing Python dependencies"

    # Upgrade pip first
    pip install --upgrade pip --quiet 2>/dev/null
    log_ok "pip upgraded"

    # Install required packages
    local packages=("piper-tts" "fastapi" "uvicorn[standard]")
    for pkg in "${packages[@]}"; do
        if pip show "${pkg%%[*}" &>/dev/null 2>&1; then
            log_ok "${pkg} — already installed"
        else
            log_info "Installing ${pkg}..."
            pip install "${pkg}" --quiet
            log_ok "${pkg} — installed"
        fi
    done

    # Verify piper is available
    if command -v piper &>/dev/null || python -c "import piper" &>/dev/null 2>&1; then
        log_ok "piper TTS engine is ready"
    else
        # Check if piper binary is in the venv
        if [[ -f "${VENV_DIR}/bin/piper" ]]; then
            log_ok "piper binary found at ${VENV_DIR}/bin/piper"
        else
            log_warn "piper binary not found in PATH. TTS synthesis may fail."
            log_info "You may need to install piper separately or add it to PATH."
        fi
    fi
}

###############################################################################
# Step 4: Download voices.json
###############################################################################
setup_voices_json() {
    log_step "Setting up voice catalog"

    mkdir -p "${VOICES_DIR}"

    if [[ -f "${VOICES_JSON}" && -s "${VOICES_JSON}" ]]; then
        local voice_count
        voice_count=$(python3 -c "import json; print(len(json.load(open('${VOICES_JSON}'))))")
        log_ok "voices.json exists with ${voice_count} voices"
    else
        log_info "Downloading voices.json from HuggingFace..."
        curl -sL "${HF_BASE}/voices.json" -o "${VOICES_JSON}"
        if [[ -f "${VOICES_JSON}" && -s "${VOICES_JSON}" ]]; then
            local voice_count
            voice_count=$(python3 -c "import json; print(len(json.load(open('${VOICES_JSON}'))))")
            log_ok "Downloaded voices.json (${voice_count} voices)"
        else
            log_fail "Failed to download voices.json"
            exit 1
        fi
    fi
}

###############################################################################
# Step 5: Download voice models
###############################################################################
download_voices() {
    log_step "Voice models"

    if [[ "${NO_DOWNLOAD}" == true ]]; then
        log_info "Skipping voice downloads (--no-download)"
        return
    fi

    if [[ "${DOWNLOAD_ALL}" == true ]]; then
        log_info "Downloading ALL voice models (this may take a while)..."
        if [[ -x "${SCRIPT_DIR}/download.sh" ]]; then
            bash "${SCRIPT_DIR}/download.sh"
        else
            python3 "${SCRIPT_DIR}/download_voices.py"
        fi
        return
    fi

    # Download at least the default English voice for a quick demo
    log_info "Checking default voice: ${DEFAULT_VOICE}"

    local model_path config_path
    model_path=$(python3 -c "
import json
with open('${VOICES_JSON}') as f:
    voices = json.load(f)
v = voices.get('${DEFAULT_VOICE}', {})
for fp in v.get('files', {}):
    if fp.endswith('.onnx') and not fp.endswith('.onnx.json'):
        print(fp)
        break
" 2>/dev/null)

    config_path=$(python3 -c "
import json
with open('${VOICES_JSON}') as f:
    voices = json.load(f)
v = voices.get('${DEFAULT_VOICE}', {})
for fp in v.get('files', {}):
    if fp.endswith('.onnx.json'):
        print(fp)
        break
" 2>/dev/null)

    if [[ -n "${model_path}" ]]; then
        local model_dest="${VOICES_DIR}/${model_path}"
        local config_dest="${VOICES_DIR}/${config_path}"

        if [[ -f "${model_dest}" && -s "${model_dest}" && -f "${config_dest}" && -s "${config_dest}" ]]; then
            log_ok "Default voice already downloaded"
        else
            log_info "Downloading default voice model..."
            mkdir -p "$(dirname "${model_dest}")"

            if [[ ! -f "${config_dest}" || ! -s "${config_dest}" ]]; then
                curl -sL "${HF_BASE}/${config_path}" -o "${config_dest}"
                log_ok "Downloaded config: $(basename "${config_path}")"
            fi

            if [[ ! -f "${model_dest}" || ! -s "${model_dest}" ]]; then
                curl -sL "${HF_BASE}/${model_path}" -o "${model_dest}"
                log_ok "Downloaded model: $(basename "${model_path}") ($(du -h "${model_dest}" | cut -f1))"
            fi
        fi
    fi

    # Count how many voices are already downloaded
    local downloaded_count
    downloaded_count=$(python3 -c "
import json, os
with open('${VOICES_JSON}') as f:
    voices = json.load(f)
count = 0
for key, info in voices.items():
    onnx_ok = False
    json_ok = False
    for fp in info['files']:
        dest = '${VOICES_DIR}/' + fp
        if fp.endswith('.onnx') and not fp.endswith('.onnx.json'):
            onnx_ok = os.path.exists(dest) and os.path.getsize(dest) > 0
        elif fp.endswith('.onnx.json'):
            json_ok = os.path.exists(dest) and os.path.getsize(dest) > 0
    if onnx_ok and json_ok:
        count += 1
print(count)
" 2>/dev/null)

    log_info "${downloaded_count} voice(s) downloaded out of 142 total"
    if [[ "${downloaded_count}" -lt 142 ]]; then
        log_info "To download more voices, run: ./download.sh"
        log_info "Or use: ./download.sh --lang en  (for English only)"
    fi
}

###############################################################################
# Step 6: Check port availability
###############################################################################
check_port() {
    log_step "Checking port availability"

    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
            log_warn "Port ${PORT} is already in use!"
            log_info "Try a different port: $0 --port $((PORT + 1))"
            exit 1
        fi
    elif command -v lsof &>/dev/null; then
        if lsof -i ":${PORT}" &>/dev/null; then
            log_warn "Port ${PORT} is already in use!"
            log_info "Try a different port: $0 --port $((PORT + 1))"
            exit 1
        fi
    fi
    log_ok "Port ${PORT} is available"
}

###############################################################################
# Step 7: Start the server
###############################################################################
start_server() {
    log_step "Starting Piper TTS Server"

    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                                                       ║${NC}"
    echo -e "${BOLD}║   🔊  Piper TTS Studio is starting...                 ║${NC}"
    echo -e "${BOLD}║                                                       ║${NC}"
    echo -e "${BOLD}║   URL:  ${GREEN}http://${HOST}:${PORT}${NC}${BOLD}                        ║${NC}"
    echo -e "${BOLD}║                                                       ║${NC}"
    if [[ "${HOST}" == "0.0.0.0" ]]; then
    echo -e "${BOLD}║   Local:   ${CYAN}http://localhost:${PORT}${NC}${BOLD}                    ║${NC}"
    echo -e "${BOLD}║   Network: ${CYAN}http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '0.0.0.0'):${PORT}${NC}${BOLD}             ║${NC}"
    fi
    echo -e "${BOLD}║                                                       ║${NC}"
    echo -e "${BOLD}║   Press ${RED}Ctrl+C${NC}${BOLD} to stop the server                  ║${NC}"
    echo -e "${BOLD}║                                                       ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Set up signal handling
    trap cleanup SIGINT SIGTERM

    cd "${SCRIPT_DIR}"

    if [[ "${DEV_MODE}" == true ]]; then
        log_info "Starting in development mode (auto-reload enabled)"
        uvicorn server:app --host "${HOST}" --port "${PORT}" --reload &
    else
        uvicorn server:app --host "${HOST}" --port "${PORT}" &
    fi

    SERVER_PID=$!
    log_ok "Server started (PID: ${SERVER_PID})"

    # Wait for the server to be ready
    local retries=0
    while [[ ${retries} -lt 15 ]]; do
        if curl -s "http://localhost:${PORT}/api/voices" &>/dev/null; then
            log_ok "Server is ready and responding!"
            break
        fi
        retries=$((retries + 1))
        sleep 1
    done

    if [[ ${retries} -ge 15 ]]; then
        log_warn "Server may not be ready yet. Check logs above."
    fi

    # Wait for the server process
    wait "${SERVER_PID}"
}

###############################################################################
# Main
###############################################################################
main() {
    parse_args "$@"
    log_header
    check_system
    setup_venv
    install_deps
    setup_voices_json
    download_voices
    check_port
    start_server
}

main "$@"