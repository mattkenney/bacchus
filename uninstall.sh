#!/usr/bin/env bash
# Remove bacchus from this machine: stop and remove the timers and units, the
# bacchus command, and its restic. Then ask whether to also delete the AWS stack
# and access key, and ~/.config/bacchus. The bucket and the backups in it are
# always kept.
#
# install.sh also copies this script to ~/.local/lib/bacchus/uninstall.sh, so it
# works without the checkout.
set -euo pipefail

lib_dir=$HOME/.local/lib/bacchus
conf_dir=${XDG_CONFIG_HOME:-$HOME/.config}/bacchus
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

ask() {
  local answer
  read -rp "$1 [y/N] " answer || answer=
  [[ $answer == [yY]* ]]
}

systemctl --user disable --now bacchus.timer bacchus-prune.timer 2>/dev/null || true
rm -f "$unit_dir"/bacchus*.service "$unit_dir"/bacchus*.timer
systemctl --user daemon-reload
systemctl --user reset-failed 'bacchus*' 2>/dev/null || true
rm -f "$HOME/.local/bin/bacchus"
rm -rf "$lib_dir"
echo "Removed the timers, units, bacchus command and its restic."

stack=$(sed -n 's/^BACCHUS_STACK=//p' "$conf_dir/env" 2>/dev/null || true)
repository=$(sed -n 's/^RESTIC_REPOSITORY=//p' "$conf_dir/env" 2>/dev/null || true)
if [[ -n $stack ]] && ask "Delete AWS stack $stack and its IAM user? This stops backups from every machine using it; the bucket and backups are kept."; then
  # CloudFormation can't delete a user that still has access keys it didn't create.
  for key in $(aws iam list-access-keys --user-name "$stack" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$stack" --access-key-id "$key"
  done
  aws cloudformation delete-stack --stack-name "$stack"
  aws cloudformation wait stack-delete-complete --stack-name "$stack"
  echo "Deleted stack $stack. Kept bucket ${repository##*/}; to delete the backups for"
  echo "good, empty and delete it in the S3 console."
fi

if [[ -d $conf_dir ]] && ask "Delete $conf_dir (your lists, the access key, the machine password)?"; then
  rm -r "$conf_dir"
fi
