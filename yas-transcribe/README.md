# yas-transcribe

Turn one or more video/audio links (Instagram reels, YouTube, TikTok, podcasts,
local URLs…) into one readable transcript file.

```
yt-dlp download → ffmpeg 16 kHz mono WAV → faster-whisper → one tidy document
```

## Install

```sh
sh /path/to/yas-transcribe/install.sh
# or, from a pipe:
YAS_TRANSCRIBE_RAW_BASE=https://raw.githubusercontent.com/<user>/<repo>/main \
  curl -fsSL "$YAS_TRANSCRIBE_RAW_BASE/install.sh" | sh
```

The installer puts one command, `yas-transcribe`, in `~/.local/bin` and adds that
directory to your shell startup file. Nothing else is installed at that point.

## Use

Links can be comma-, semicolon-, space- or newline-separated, or written as a
PHP-style array. The optional second positional argument is the output file.

```sh
yas-transcribe "https://www.instagram.com/reel/AAA/, https://www.instagram.com/reel/BBB/"
yas-transcribe "['https://a', 'https://b', 'https://c']" transcripts.txt
yas-transcribe "https://a https://b" -o notes/transcripts.md --format md
```

Options that matter day to day:

| Option | Meaning |
| --- | --- |
| `-o, --out FILE` | Output file, or a directory (a dated file is created inside) |
| `--format text\|md` | Plain text (default) or Markdown |
| `--model NAME` | `tiny`, `base`, `small` (default), `medium`, `large-v3`, any HF repo id |
| `--language CODE` | Spoken language or `auto` (default) |
| `--prompt TEXT` | Names/jargon the model should spell correctly |
| `--caption` | Also print the post caption (truncated) under each header |
| `-t, --timestamps` | Keep `[mm:ss]` markers per caption line |
| `--cookies FILE` / `--cookies-from-browser B` | For login-walled posts |
| `--keep` | Keep media, WAV and logs for inspection |
| `-y, --yes` | Answer yes to every install/download question (CI-friendly) |
| `--dry-run` | Parse links and show the plan without downloading |
| `--check` | Show which dependencies and models are present |
| `--setup` | Install dependencies + model, then stop |

Full list: `yas-transcribe --help`.

## First run is interactive (on purpose)

Nothing is installed or downloaded silently:

1. **ffmpeg** missing → offers the right command for your package manager.
2. **yt-dlp** missing → offers `uv tool install`, `pipx install`, or `pip --user`.
3. **Speech engine** missing → creates a private venv
   (`~/.local/share/yas-transcribe/venv`, ~120 MB) and installs
   `faster-whisper` there. Nothing is installed system-wide.
4. **Model** missing → shows the download size and asks before fetching it
   (`tiny` ~75 MB … `large-v3` ~3.1 GB) into the standard Hugging Face cache
   (`~/.cache/huggingface/hub`), so models already used by other tools are
   reused instead of downloaded twice.

In a non-interactive shell (cron, pipe) the script refuses to install anything
unless you pass `--yes`.

## Portability

* No hardcoded user paths: everything resolves through `$HOME`, `$XDG_DATA_HOME`,
  `$TMPDIR`, `command -v`, plus a few standard fallback locations.
* Override any location: `YAS_TRANSCRIBE_HOME`, `YAS_TRANSCRIBE_MODEL_DIR`,
  `TMPDIR`, `--data-dir`, `--model-dir`, `--workdir`.
* Runs on Linux and macOS with Bash 3.2+, `curl`/`wget`, `python3`.
* Scratch files live in a `mktemp -d` directory and are removed on exit
  (or kept with `--keep`).
* Failed links never abort the run: they are marked inside the document and the
  script exits with status 1 at the end.

## Output shape

```
===============================================================================
1) https://www.instagram.com/reel/...
   Account: Paul and April (@wisdominthat)
   Posted: 2026-10-21 — length ~70s
===============================================================================

Sex is not love. Dating is not love. …

```

Markdown mode uses `## 1. <url>` headings with the same metadata as bold lines.
Clips without speech are labelled `[No spoken audio detected in this clip.]`
instead of leaving an empty section.

## Notes

* Transcripts are machine-generated; verify before quoting.
* The script keeps no cookies or credentials. Use `--cookies` for age/login
  gated posts and delete the file afterwards.
* Instagram and other platforms change often: keep `yt-dlp` fresh
  (`uv tool upgrade yt-dlp`).

## License

MPL-2.0
