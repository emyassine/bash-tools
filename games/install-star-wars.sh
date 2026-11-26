#!/usr/bin/env bash
# Usage:
#   ./install-star-wars.sh                 Choose a game interactively
#   ./install-star-wars.sh phantom-menace  Install The Phantom Menace
#   ./install-star-wars.sh racer           Install Episode I: Racer
#   ./install-star-wars.sh both            Install both games
#   ./install-star-wars.sh --version       Show the script version
#
# Each installed game gets an application-menu entry and a desktop shortcut.
# Run ./install-star-wars.sh --help for configuration options.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly DREAMM_VERSION="${DREAMM_VERSION:-4.0}"
readonly HOME_GAMES_DIR="${HOME}/Games"
readonly PHANTOM_DIR="${PHANTOM_MENACE_INSTALL_DIR:-$HOME_GAMES_DIR/PhantomMenace}"
readonly RACER_DIR="${RACER_INSTALL_DIR:-$HOME_GAMES_DIR/StarWarsRacer}"
readonly PHANTOM_URL="${PHANTOM_MENACE_GAME_ARCHIVE_URL:-https://archive.org/download/StarWarsEpisodeIThePhantomMenaceUSAEurope/Star%20Wars%20-%20Episode%20I%20-%20The%20Phantom%20Menace%20%28USA%2C%20Europe%29.zip}"
readonly RACER_URL="${RACER_GAME_ISO_URL:-https://archive.org/download/star_wars_racer_episode_1_1999/Star%20Wars%20Racer%20Episode%201.iso}"
readonly PHANTOM_MOUSE_SCALE="${PHANTOM_MENACE_MOUSE_SCALE:-2.0}"

log() {
    printf '[install-star-wars] %s\n' "$*"
}

die() {
    printf '[install-star-wars] Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<USAGE
install-star-wars.sh ${SCRIPT_VERSION}

Usage: install-star-wars.sh [phantom-menace|racer|both]

Run without an argument to choose a game interactively.

Environment variables:
  DREAMM_VERSION                     DREAMM release (default: ${DREAMM_VERSION})
  PHANTOM_MENACE_INSTALL_DIR         Install folder (default: ~/Games/PhantomMenace)
  RACER_INSTALL_DIR                  Install folder (default: ~/Games/StarWarsRacer)
  PHANTOM_MENACE_GAME_ARCHIVE_URL    ZIP archive URL for The Phantom Menace CD
  RACER_GAME_ISO_URL                 ISO URL for Episode I: Racer
  PHANTOM_MENACE_MOUSE_SCALE         Mouse scale for that game's launcher (default: 2.0)

Each installed game gets an application-menu entry and a desktop shortcut.
USAGE
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_privileged() {
    if [[ ${EUID} -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "Missing system libraries. Install them with your distribution package manager and rerun this script."
    fi
}

install_runtime_dependencies() {
    local missing=()
    local ldconfig_tool
    ldconfig_tool=$(command -v ldconfig 2>/dev/null || true)
    if [[ -z "$ldconfig_tool" ]]; then
        for candidate in /sbin/ldconfig /usr/sbin/ldconfig; do
            if [[ -x "$candidate" ]]; then
                ldconfig_tool="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$ldconfig_tool" ]] || ! "$ldconfig_tool" -p 2>/dev/null | grep 'libSDL2-2\.0\.so\.0' >/dev/null; then
        missing+=(sdl)
    fi
    if [[ -z "$ldconfig_tool" ]] || ! "$ldconfig_tool" -p 2>/dev/null | grep 'libcurl\.so\.4' >/dev/null; then
        missing+=(curl)
    fi
    ((${#missing[@]} == 0)) && return 0

    log "Installing DREAMM runtime libraries."
    if command -v apt-get >/dev/null 2>&1; then
        run_privileged apt-get update
        run_privileged apt-get install -y libsdl2-2.0-0 libcurl4
    elif command -v dnf >/dev/null 2>&1; then
        run_privileged dnf install -y SDL2 libcurl
    elif command -v pacman >/dev/null 2>&1; then
        run_privileged pacman -S --needed --noconfirm sdl2 curl
    elif command -v zypper >/dev/null 2>&1; then
        run_privileged zypper --non-interactive install libSDL2-2_0-0 libcurl4
    else
        die "Could not identify a supported package manager for SDL2 and libcurl."
    fi
}

desktop_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    printf '"%s"' "$value"
}

download_file() {
    local url="$1"
    local destination="$2"
    local download_dir
    download_dir=$(dirname "$destination")
    mkdir -p "$download_dir"

    if command -v aria2c >/dev/null 2>&1; then
        aria2c --continue=true --max-connection-per-server=16 --split=16 \
            --min-split-size=1M --file-allocation=none \
            --out="$(basename "$destination")" --dir="$download_dir" "$url"
    else
        [[ ! -f "$destination.aria2" ]] || die "Install aria2c to resume this partial download."
        curl -fL --retry 3 --continue-at - -o "$destination" "$url"
    fi
}

ensure_engine() {
    local install_root="$1"
    local engine_dir="$install_root/engine"
    local archive_dir="${XDG_CACHE_HOME:-$HOME/.cache}/star-wars-dreamm"
    local engine_archive="$archive_dir/dreamm-${DREAMM_VERSION}-${dreamm_arch}.tgz"

    mkdir -p "$engine_dir" "$archive_dir"
    if [[ ! -x "$engine_dir/dreamm" ]]; then
        local engine_url="https://dreamm.aarongiles.com/releases/dreamm-${DREAMM_VERSION}-linux-${dreamm_arch}.tgz"
        log "Downloading DREAMM ${DREAMM_VERSION} for ${dreamm_arch}."
        download_file "$engine_url" "$engine_archive"
        tar -xzf "$engine_archive" -C "$engine_dir"
        : > "$engine_dir/config.json"
    fi
    [[ -x "$engine_dir/dreamm" ]] || die "DREAMM executable is missing from $engine_dir."
}

install_launcher() {
    local app_id="$1"
    local app_name="$2"
    local game_kind="$3"
    local install_root="$4"
    local mouse_scale="$5"
    local applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local desktop_dir="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
    local engine_dir="$install_root/engine"
    local launcher="$applications_dir/$app_id.desktop"
    local executable="$engine_dir/dreamm"
    local icon="$engine_dir/dreamm.png"
    local game_path="$engine_dir/game"

    if command -v xdg-user-dir >/dev/null 2>&1; then
        desktop_dir=$(xdg-user-dir DESKTOP 2>/dev/null || printf '%s' "$desktop_dir")
    fi

    mkdir -p "$applications_dir"
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Version=1.0\n'
        printf 'Name=%s\n' "$app_name"
        printf 'GenericName=Classic Star Wars game\n'
        printf 'Comment=Play %s with DREAMM\n' "$app_name"
        printf 'Exec=env SDL_MOUSE_NORMAL_SPEED_SCALE=%s SDL_MOUSE_RELATIVE_SPEED_SCALE=%s %s -windowed -run %s\n' \
            "$mouse_scale" "$mouse_scale" "$(desktop_quote "$executable")" "$(desktop_quote "$game_path")"
        printf 'Icon=%s\n' "$icon"
        printf 'Terminal=false\n'
        printf 'Categories=Game;Emulator;\n'
        printf 'StartupNotify=true\n'
        printf 'X-StarWars-Game=%s\n' "$game_kind"
    } > "$launcher"
    chmod +x "$launcher"

    if [[ -d "$desktop_dir" ]]; then
        cp "$launcher" "$desktop_dir/$app_id.desktop"
        chmod +x "$desktop_dir/$app_id.desktop"
        if command -v gio >/dev/null 2>&1; then
            gio set "$desktop_dir/$app_id.desktop" metadata::trusted true 2>/dev/null || true
        fi
    fi
    log "Application launcher installed: $launcher"
}

refresh_desktop_database() {
    local applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$applications_dir" || true
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    command -v kbuildsycoca5 >/dev/null 2>&1 && kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
}

install_phantom_menace() {
    local install_root="$PHANTOM_DIR"
    local engine_dir="$install_root/engine"
    local game_dir="$engine_dir/game"
    local cd_dir="$install_root/cd"
    local archive="$cd_dir/phantom-menace-cd.zip"

    mkdir -p "$cd_dir"
    ensure_engine "$install_root"

    if [[ ! -f "$game_dir/WMAIN.EXE" ]]; then
        if [[ ! -f "$archive" ]] || ! unzip -tq "$archive" >/dev/null 2>&1; then
            log "Downloading The Phantom Menace CD archive."
            download_file "$PHANTOM_URL" "$archive"
        fi
        unzip -tq "$archive" >/dev/null || die "The Phantom Menace CD archive is incomplete or invalid."
        log "Extracting The Phantom Menace CD."
        mkdir -p "$cd_dir/media"
        unzip -oq "$archive" -d "$cd_dir/media"

        log "Installing The Phantom Menace with DREAMM."
        (cd "$engine_dir" && ./dreamm -autoinstall "$cd_dir/media")
        move_installed_game "$engine_dir" lec-phantom "$game_dir"
    fi

    [[ -f "$game_dir/WMAIN.EXE" ]] || die "The Phantom Menace executable is missing."
    install_launcher "star-wars-phantom-menace" \
        "Star Wars: Episode I - The Phantom Menace" phantom-menace "$install_root" "$PHANTOM_MOUSE_SCALE"
}

install_racer() {
    local install_root="$RACER_DIR"
    local engine_dir="$install_root/engine"
    local game_dir="$engine_dir/game"
    local cd_dir="$install_root/cd"
    local iso="$cd_dir/racer.iso"

    mkdir -p "$cd_dir"
    ensure_engine "$install_root"

    if [[ ! -f "$game_dir/SWEP1RCR.EXE" ]]; then
        if [[ ! -f "$iso" || -f "$iso.aria2" ]] || ! file "$iso" | grep 'ISO 9660' >/dev/null; then
            log "Downloading the Episode I: Racer CD image from the Lutris recipe source."
            download_file "$RACER_URL" "$iso"
        fi
        [[ ! -f "$iso.aria2" ]] || die "The Racer CD image download is incomplete. Run this script again to resume it."
        file "$iso" | grep 'ISO 9660' >/dev/null || die "The Racer CD image is incomplete or invalid."

        log "Installing Episode I: Racer with DREAMM."
        (cd "$engine_dir" && ./dreamm -autoinstall "$iso")
        move_installed_game "$engine_dir" lec-racer "$game_dir"
    fi

    [[ -f "$game_dir/SWEP1RCR.EXE" ]] || die "The Racer executable is missing."
    install_launcher "star-wars-episode-i-racer" \
        "STAR WARS Episode I Racer" racer "$install_root" "1.0"
}

move_installed_game() {
    local engine_dir="$1"
    local game_slug="$2"
    local game_dir="$3"
    local install_dir="$engine_dir/install/$game_slug"
    local installed_game

    installed_game=$(find "$install_dir" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)
    [[ -n "$installed_game" ]] || die "DREAMM did not create the expected installation at $install_dir."
    if [[ -e "$game_dir" ]]; then
        mv "$game_dir" "${game_dir}.previous.$(date +%s)"
    fi
    mv "$installed_game" "$game_dir"
}

case "$(uname -m)" in
    x86_64|amd64) dreamm_arch="x64" ;;
    aarch64|arm64) dreamm_arch="arm64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

case "${1:-}" in
    --version|-V)
        printf '%s %s\n' "install-star-wars.sh" "$SCRIPT_VERSION"
        exit 0
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    phantom-menace|phantom)
        selection="phantom-menace"
        ;;
    racer)
        selection="racer"
        ;;
    both)
        selection="both"
        ;;
    "")
        if [[ ! -t 0 ]]; then
            usage
            exit 2
        fi
        printf 'Choose a game to install:\n'
        printf '  1) Star Wars: Episode I - The Phantom Menace\n'
        printf '  2) STAR WARS Episode I Racer\n'
        printf '  3) Both games\n'
        read -r -p 'Selection [1-3]: ' choice
        case "$choice" in
            1) selection="phantom-menace" ;;
            2) selection="racer" ;;
            3) selection="both" ;;
            *) die "Invalid selection." ;;
        esac
        ;;
    *)
        usage
        die "Unknown game selection: $1"
        ;;
esac

require_command curl
require_command tar
require_command unzip
require_command file
install_runtime_dependencies

case "$selection" in
    phantom-menace) install_phantom_menace ;;
    racer) install_racer ;;
    both)
        install_phantom_menace
        install_racer
        ;;
esac

refresh_desktop_database
log "Installation complete. Search for the game title in the application menu or use its desktop shortcut."
