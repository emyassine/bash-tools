#!/bin/sh
# Install yas-transcribe. Runtime behavior lives in the separate yas-transcribe script.
#
# Local checkout:   sh install.sh
# Remote one-liner: curl -fsSL <url>/install.sh | sh
#   (pipe mode needs YAS_TRANSCRIBE_RAW_BASE, e.g.
#    YAS_TRANSCRIBE_RAW_BASE=https://raw.githubusercontent.com/<user>/<repo>/main)
set -eu

SCRIPT_NAME='yas-transcribe'
INSTALL_DIR="${YAS_TRANSCRIBE_INSTALL_DIR:-$HOME/.local/bin}"
DEST="$INSTALL_DIR/$SCRIPT_NAME"
RAW_BASE="${YAS_TRANSCRIBE_RAW_BASE:-}"

say() { printf '%s\n' "$SCRIPT_NAME installer: $*"; }
fail() { say "Error: $*" >&2; exit 1; }

mkdir -p "$INSTALL_DIR" || fail "could not create $INSTALL_DIR"
tmp_file=$(mktemp "${TMPDIR:-/tmp}/$SCRIPT_NAME.XXXXXX") || fail 'could not create a temporary file'
trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

# Prefer the copy sitting next to this installer (local checkout);
# fall back to a configured raw URL (pipe install) with curl or wget.
local_script=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/$SCRIPT_NAME
if [ -f "$local_script" ]; then
    cp "$local_script" "$tmp_file" || fail "could not read $local_script"
elif [ -n "$RAW_BASE" ]; then
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RAW_BASE/$SCRIPT_NAME" -o "$tmp_file" || fail 'download failed; check the URL and your connection'
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$RAW_BASE/$SCRIPT_NAME" -O "$tmp_file" || fail 'download failed; check the URL and your connection'
    else
        fail 'curl or wget is required for a remote install'
    fi
else
    fail "cannot find $SCRIPT_NAME next to this installer; set YAS_TRANSCRIBE_RAW_BASE=<raw-url-base> for a remote install"
fi

[ -s "$tmp_file" ] || fail 'downloaded command is empty'
command -v bash >/dev/null 2>&1 || fail 'bash is required'
bash -n "$tmp_file" || fail 'the downloaded script is not valid bash'
install -m 0755 "$tmp_file" "$DEST" || fail "could not install to $DEST"
say "Installed $DEST"

shell_name=$(basename "${SHELL:-sh}")
path_line='case ":$PATH:" in *:"$HOME/.local/bin":*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'

add_path_setup() {
    target=$1
    mkdir -p "$(dirname "$target")" || fail "could not prepare $(dirname "$target")"
    : >> "$target" || fail "could not update $target"
    if ! grep -Fq "$path_line" "$target"; then
        {
            printf '\n# Added by %s installer\n%s\n' "$SCRIPT_NAME" "$path_line"
        } >> "$target" || fail "could not update $target"
        say "Added ~/.local/bin to PATH in $target"
    else
        say "PATH setup already exists in $target"
    fi
}

case "$shell_name" in
    zsh)
        add_path_setup "$HOME/.zshrc"
        reload_hint='. "$HOME/.zshrc"'
        ;;
    bash)
        add_path_setup "$HOME/.bashrc"
        # macOS Terminal commonly starts login Bash, which reads .bash_profile.
        if [ "$(uname -s 2>/dev/null || true)" = Darwin ] || [ -f "$HOME/.bash_profile" ]; then
            add_path_setup "$HOME/.bash_profile"
            reload_hint='. "$HOME/.bash_profile"'
        else
            reload_hint='. "$HOME/.bashrc"'
        fi
        ;;
    *)
        add_path_setup "$HOME/.profile"
        reload_hint='. "$HOME/.profile"'
        ;;
esac

say 'Then run:'
say "  $SCRIPT_NAME --check                              # see what is available"
say "  $SCRIPT_NAME \"https://a, https://b\" out.txt       # transcribe"
say "It will offer to install ffmpeg / yt-dlp and download the chosen model on first use."
