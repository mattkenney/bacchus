#!/usr/bin/env bash
# Set up bacchus on this machine, or bring it up to date. Safe to re-run.
#   usage: ./install.sh [STACK]
#
# - installs its own restic into ~/.local/lib/bacchus, separate from any other
#   restic, if it's missing or older than below
# - copies bacchus into ~/.local/bin, uninstall.sh into ~/.local/lib/bacchus, and
#   the systemd user units into place, so nothing depends on this checkout later
# - creates ~/.config/bacchus/{includes,excludes} from the examples
# - first run only: creates the AWS resources and this machine's access key with
#   aws/setup.sh [STACK], which needs AWS credentials, e.g. from `aws login`
# - creates the repository, or connects this machine to it (bacchus init)
# - turns on the timers
set -euo pipefail

# Checksums of the release's .bz2 files, from its SHA256SUMS (signed by restic's
# release key, CF8F18F2844575973F79D4E191A6868BD3F7A907).
restic_version=0.19.1
declare -A restic_sha256=(
  [amd64]=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
  [arm64]=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465
)

here=$(dirname "$(readlink -f "$0")")
lib_dir=$HOME/.local/lib/bacchus
conf_dir=${XDG_CONFIG_HOME:-$HOME/.config}/bacchus
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

if [[ -e $conf_dir/env ]]; then
  [[ $# -eq 0 ]] || echo "$conf_dir/env exists, so ignoring STACK $1"
elif ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "The first install creates AWS resources and needs the AWS CLI with" >&2
  echo "credentials: run aws login, then install.sh again." >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$lib_dir" "$unit_dir"

# Keep a newer restic, e.g. from `bacchus self-update`.
current=$("$lib_dir/restic" version 2>/dev/null | cut -d' ' -f2 || true)
if [[ -n $current && $(printf '%s\n' "$restic_version" "$current" | sort -V | head -1) == "$restic_version" ]]; then
  echo "Using restic $current"
else
  case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) echo "No restic download set up for $(uname -m); put restic $restic_version or newer in $lib_dir yourself" >&2; exit 1 ;;
  esac
  file=restic_${restic_version}_linux_$arch.bz2
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/$file" "https://github.com/restic/restic/releases/download/v$restic_version/$file"
  echo "${restic_sha256[$arch]}  $tmp/$file" | sha256sum --check --quiet
  bunzip2 -c "$tmp/$file" >"$tmp/restic"
  install -m 755 "$tmp/restic" "$lib_dir/restic"
  echo "Installed restic $restic_version in $lib_dir"
fi

install -m 755 "$here/bin/bacchus" "$HOME/.local/bin/bacchus"
install -m 755 "$here/uninstall.sh" "$lib_dir/uninstall.sh"
install -m 644 "$here"/systemd/* "$unit_dir/"
systemctl --user daemon-reload

install -d -m 700 "$conf_dir"
new_lists=
for list in includes excludes; do
  if [[ ! -e $conf_dir/$list ]]; then
    install -m 600 "$here/$list.example" "$conf_dir/$list"
    new_lists+=" $conf_dir/$list"
  fi
done

if [[ ! -e $conf_dir/env ]]; then
  "$here/aws/setup.sh" "$@"
fi
"$HOME/.local/bin/bacchus" init
systemctl --user enable --now bacchus.timer bacchus-prune.timer

echo
echo "Done. Backups run daily; 'bacchus snapshots' lists them."
if [[ -n $new_lists ]]; then
  echo "Created from the examples:$new_lists"
  echo "Edit them before the first backup, unless you're about to restore yours."
fi
