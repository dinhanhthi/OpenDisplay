#!/usr/bin/env bash
#
# hidpi-override.sh - Phase 1 spike: generates, installs, removes, shows and checks the display
# override plist that should add a HiDPI 2560x1080 mode (5120x2160 backing) to the LG ULTRAWIDE.
#
# Usage:
#   tools/hidpi-override.sh generate <A|B|C|D|E>   # write build/spike/DisplayProductID-7826
#   tools/hidpi-override.sh install                # copy it to /Library/Displays (admin dialog)
#   tools/hidpi-override.sh undo                   # remove it again (admin dialog)
#   tools/hidpi-override.sh root-command <install|undo>   # print what would run as root
#   tools/hidpi-override.sh status                 # is an override installed?
#   tools/hidpi-override.sh check                  # did the mode appear? exit 0 = FOUND
#
# Variants (one scale-resolutions entry = width, height and flags as big-endian 32-bit values):
#   A  16-byte entry (width, height, 00000001, 00200000), canary name, target only
#   B  12-byte entry (width, height, 00000001), canary name, target only
#   C  A plus target-default-ppmm
#   D  the encoding "check" found working, plain name, five sizes (measures the ceiling)
#   E  the encoding "check" found working, plain name, target only
#
# Written for the bash 3.2 that ships with macOS.
#
set -euo pipefail

readonly VENDOR=0x1e6d
readonly MODEL=0x7826
readonly NATIVE_WIDTH=3440
readonly NATIVE_HEIGHT=1440
readonly EXPECTED_MODE="2560x1080@2x@100"

readonly CANARY_NAME="LG ULTRAWIDE od-spike"
readonly PLAIN_NAME="LG ULTRAWIDE"
readonly TARGET_SIZE="5120x2160"
readonly CEILING_SIZES="5120x2160 5160x2160 6020x2520 4300x1800 6880x2880"
readonly DEFAULT_PPMM="10.0699301"

# Where macOS reads the override (unpadded lowercase hex, no extension).
readonly DISPLAYS="/Library/Displays"
readonly OVERRIDES="$DISPLAYS/Contents/Resources/Overrides"
readonly TARGET_DIR="$OVERRIDES/DisplayVendorID-${VENDOR#0x}"
readonly TARGET="$TARGET_DIR/DisplayProductID-${MODEL#0x}"

# The WindowServer preference that "install" turns on and "undo" turns off again.
readonly PREF_DOMAIN="/Library/Preferences/com.apple.windowserver"
readonly PREF_KEY="DisplayResolutionEnabled"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SPIKE="$REPO_ROOT/build/spike"
readonly GENERATED="$SPIKE/DisplayProductID-${MODEL#0x}"
readonly LIST_MODES="$SPIKE/list-modes"
readonly BASELINE="$SPIKE/modes-before.txt"
readonly STATE_FILE="$REPO_ROOT/tools/hidpi-spike-state.md"

usage() {
  cat >&2 <<EOF
usage: tools/hidpi-override.sh generate <A|B|C|D|E>
       tools/hidpi-override.sh install | undo | status | check
       tools/hidpi-override.sh root-command <install|undo>
EOF
  exit 2
}

die() {
  echo "hidpi-override: $*" >&2
  exit 1
}

# MARK: generate

# One scale-resolutions entry as base64. $1 = pixel width, $2 = pixel height, $3 = encoding.
entry() {
  local hex
  hex="$(printf '%08x%08x00000001' "$1" "$2")"
  if [[ "$3" != B ]]; then hex="${hex}00200000"; fi
  printf '%s' "$hex" | xxd -r -p | base64
}

cmd_generate() {
  local variant="$1" encoding name sizes size data entries=""
  case "$variant" in
    A | B | C)
      encoding="$variant"
      name="$CANARY_NAME"
      sizes="$TARGET_SIZE"
      ;;
    D | E)
      if [[ ! -f "$SPIKE/winning-encoding" ]]; then
        die "generate $variant: winning encoding not known yet" \
          "(\"check\" writes build/spike/winning-encoding once variant A, B or C is FOUND)"
      fi
      encoding="$(cat "$SPIKE/winning-encoding")"
      case "$encoding" in
        A | B | C) ;;
        *) die "generate $variant: build/spike/winning-encoding holds \"$encoding\", expected A, B or C" ;;
      esac
      name="$PLAIN_NAME"
      if [[ "$variant" == D ]]; then sizes="$CEILING_SIZES"; else sizes="$TARGET_SIZE"; fi
      ;;
    *) usage ;;
  esac

  for size in $sizes; do
    data="$(entry "${size%x*}" "${size#*x}" "$encoding")"
    entries="$entries    <data>$data</data>"$'\n'
  done

  mkdir -p "$SPIKE"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DisplayVendorID</key>
  <integer>$((VENDOR))</integer>
  <key>DisplayProductID</key>
  <integer>$((MODEL))</integer>
  <key>DisplayProductName</key>
  <string>$name</string>
  <key>scale-resolutions</key>
  <array>
EOF
    printf '%s' "$entries"
    echo "  </array>"
    if [[ "$encoding" == C ]]; then
      echo "  <key>target-default-ppmm</key>"
      echo "  <real>$DEFAULT_PPMM</real>"
    fi
    echo "</dict>"
    echo "</plist>"
  } >"$GENERATED.tmp"
  plutil -lint -s "$GENERATED.tmp"
  mv "$GENERATED.tmp" "$GENERATED"
  printf '%s\n' "$variant" >"$SPIKE/current-variant"
  echo "generated variant $variant (encoding $encoding, sizes: $sizes): build/spike/${GENERATED##*/}"
}

# MARK: install, undo

# $1 in single quotes for sh.
shell_quoted() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The exact shell command that "install" or "undo" runs as root. $1 = install | undo.
# Fixed paths only, apart from the generated file in this checkout.
root_command() {
  local file dir command
  file="$(shell_quoted "$TARGET")"
  case "$1" in
    install)
      dir="$(shell_quoted "$TARGET_DIR")"
      command="mkdir -p $dir && cp $(shell_quoted "$GENERATED") $file && chown root:wheel $file && chmod 644 $file"
      echo "$command && /usr/bin/defaults write $PREF_DOMAIN $PREF_KEY -bool YES"
      ;;
    undo)
      # Only empty directories go: a failing rmdir is ignored, a failing rm is not.
      command="rm -f $file && {"
      for dir in "$TARGET_DIR" "$OVERRIDES" "$DISPLAYS/Contents/Resources" "$DISPLAYS/Contents" "$DISPLAYS"; do
        command="$command rmdir $(shell_quoted "$dir");"
      done
      # Same for the preference: its file goes only when no other key is left in it.
      command="$command /usr/bin/defaults delete $PREF_DOMAIN $PREF_KEY;"
      command="$command if [ \"\$(/usr/bin/plutil -convert json -o - $PREF_DOMAIN.plist 2>/dev/null)\" = \"{}\" ];"
      command="$command then rm -f $PREF_DOMAIN.plist; fi;"
      echo "$command true; }"
      ;;
    *) usage ;;
  esac
}

# Runs root_command through the system's admin dialog, which collects the password itself.
# $1 = install | undo, $2 = the dialog's prompt. Returns only when osascript exits 0.
run_as_root() {
  local command script error
  command="$(root_command "$1")"
  # Inside an AppleScript string literal, only \ and " need escaping.
  command="$(printf '%s' "$command" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  script="do shell script \"$command\" with prompt \"$2\" with administrator privileges"
  if error="$(/usr/bin/osascript -e "$script" 2>&1 >/dev/null)"; then
    return 0
  fi
  if [[ -n "$error" ]]; then printf '%s\n' "$error" >&2; fi
  if [[ "$error" == *"(-128)"* ]]; then
    echo "$1 cancelled, nothing changed"
  else
    echo "$1 failed"
  fi
  exit 1
}

cmd_install() {
  if [[ ! -f "$GENERATED" || ! -f "$SPIKE/current-variant" ]]; then
    die "nothing to install: run \"generate <A|B|C|D|E>\" first"
  fi
  run_as_root install "OpenDisplay spike: install a display override for the LG ULTRAWIDE."
  cp "$SPIKE/current-variant" "$SPIKE/installed-variant"
  echo "installed variant $(cat "$SPIKE/installed-variant"): $TARGET"
}

cmd_undo() {
  run_as_root undo "OpenDisplay spike: remove the display override for the LG ULTRAWIDE."
  rm -f "$SPIKE/installed-variant"
  echo "removed: $TARGET"
}

# MARK: status, check

# The preference's value, or "unset" when the key or the domain does not exist.
windowserver_pref() {
  /usr/bin/defaults read "$PREF_DOMAIN" "$PREF_KEY" 2>/dev/null || echo "unset"
}

cmd_status() {
  if [[ -f "$TARGET" ]]; then
    echo "installed"
    plutil -p "$TARGET"
  else
    echo "not installed"
  fi
  echo "windowserver-pref: $(windowserver_pref)"
}

# Prints one line of check's report and keeps it for the state file.
REPORT=""
say() {
  printf '%s\n' "$1"
  REPORT="$REPORT$1"$'\n'
}

# Reads only. Every command whose non-zero exit is a normal answer is guarded, so the last
# line is always reached and the exit status is the one of "list-modes --expect".
cmd_check() {
  local listing header added removed line width height kind result variant status=0

  if [[ ! -e "$TARGET" ]]; then
    say "installed-file: absent"
  elif cmp -s "$TARGET" "$GENERATED" 2>/dev/null; then
    say "installed-file: identical"
  else
    say "installed-file: differs"
  fi

  if pgrep -x BetterDisplay >/dev/null 2>&1; then
    say "BetterDisplay: running"
  else
    say "BetterDisplay: not running"
  fi
  say "windowserver-pref: $(windowserver_pref)"

  rm -f "$SPIKE/modes-now.txt" || true
  listing="$("$LIST_MODES" --vendor "$VENDOR" --model "$MODEL" --dump "$SPIKE/modes-now.txt")" || listing=""
  header="${listing%%$'\n'*}"
  if [[ -n "$header" ]]; then
    say "$header"
  else
    say "display: none with vendor=$VENDOR model=$MODEL"
  fi

  if [[ -z "$header" || ! -f "$BASELINE" || ! -f "$SPIKE/modes-now.txt" ]]; then
    say "added: not compared"
    say "removed: not compared"
  else
    added="$(LC_ALL=C comm -13 "$BASELINE" "$SPIKE/modes-now.txt")" || added=""
    removed="$(LC_ALL=C comm -23 "$BASELINE" "$SPIKE/modes-now.txt")" || removed=""
    say "added: $(grep -c . <<<"$added" || true)"
    while IFS= read -r line; do
      if [[ -z "$line" ]]; then continue; fi
      say "+ $line"
      IFS='x ' read -r width height _ _ _ kind <<<"$line" || true
      if [[ "$kind" == LoDPI ]] && ((width > NATIVE_WIDTH || height > NATIVE_HEIGHT)); then
        say "WARNING: LoDPI mode above native: $line"
      fi
    done <<<"$added"
    say "removed: $(grep -c . <<<"$removed" || true)"
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then say "- $line"; fi
    done <<<"$removed"
  fi

  result="$("$LIST_MODES" --vendor "$VENDOR" --model "$MODEL" --expect "$EXPECTED_MODE")" || status=$?
  say "${result:-no result from list-modes (exit status $status)}"

  variant="none"
  if [[ -f "$SPIKE/installed-variant" ]]; then
    variant="$(cat "$SPIKE/installed-variant")" || variant="unreadable"
  fi
  {
    printf '\n## Check %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '```\ninstalled-variant: %s\n%s```\n' "$variant" "$REPORT"
  } >>"$STATE_FILE" || echo "hidpi-override: could not append to tools/hidpi-spike-state.md" >&2

  # D and E read this file, so only a gate variant may write it.
  if [[ "$status" -eq 0 ]]; then
    case "$variant" in
      A | B | C)
        printf '%s\n' "$variant" >"$SPIKE/winning-encoding" ||
          echo "hidpi-override: could not write build/spike/winning-encoding" >&2
        ;;
    esac
  fi
  exit "$status"
}

case "${1:-}" in
  generate) cmd_generate "${2:-}" ;;
  install) cmd_install ;;
  undo) cmd_undo ;;
  root-command) root_command "${2:-}" ;;
  status) cmd_status ;;
  check) cmd_check ;;
  *) usage ;;
esac
