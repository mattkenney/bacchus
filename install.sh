#!/usr/bin/env bash
# Link bacchus into ~/.local/bin, install the systemd user units, create
# ~/.config/bacchus/{includes,excludes} from the examples if they don't exist,
# and install restic into ~/.local/bin if it's missing or older than below.
# Safe to re-run after editing the units.
set -euo pipefail

# Checksums of the release's .bz2 files, from its SHA256SUMS (signed by restic's
# release key, CF8F18F2844575973F79D4E191A6868BD3F7A907).
restic_version=0.19.1
declare -A restic_sha256=(
  [amd64]=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
  [arm64]=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465
)

here=$(dirname "$(readlink -f "$0")")
conf_dir=${XDG_CONFIG_HOME:-$HOME/.config}/bacchus
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

mkdir -p "$HOME/.local/bin" "$unit_dir"
ln -sfn "$here/bin/bacchus" "$HOME/.local/bin/bacchus"
install -m 644 "$here"/systemd/* "$unit_dir/"
systemctl --user daemon-reload

(
  umask 077
  mkdir -p "$conf_dir"
  for list in includes excludes; do
    if [[ ! -e $conf_dir/$list ]]; then
      cp "$here/$list.example" "$conf_dir/$list"
      echo "Created $conf_dir/$list from $list.example"
    fi
  done
)

# Same lookup order as bin/bacchus.
PATH=$HOME/.local/bin:$PATH
current=$(restic version 2>/dev/null | cut -d' ' -f2 || true)
if [[ -n $current && $(printf '%s\n' "$restic_version" "$current" | sort -V | head -1) == "$restic_version" ]]; then
  echo "Using restic $current"
  exit 0
fi

case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "No restic download set up for $(uname -m); install restic $restic_version or newer yourself" >&2; exit 1 ;;
esac
file=restic_${restic_version}_linux_$arch.bz2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$file" "https://github.com/restic/restic/releases/download/v$restic_version/$file"
echo "${restic_sha256[$arch]}  $tmp/$file" | sha256sum --check --quiet
bunzip2 -c "$tmp/$file" >"$tmp/restic"
install -m 755 "$tmp/restic" "$HOME/.local/bin/restic"
echo "Installed restic $restic_version in ~/.local/bin"
