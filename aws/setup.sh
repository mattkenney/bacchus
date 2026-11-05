#!/usr/bin/env bash
# Create or update the CloudFormation stack (bucket and backup-only IAM user),
# then give this machine an access key for that user, written to
# ~/.config/bacchus/env.
#
# Run with credentials that can manage CloudFormation, S3 and IAM, e.g. after
# `aws login`. On a replacement machine, pass the old machine's stack name to
# connect to its backups.
#   usage: aws/setup.sh [STACK]
# STACK defaults to the one this machine already uses, else bacchus-<hostname>.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
conf_dir=${XDG_CONFIG_HOME:-$HOME/.config}/bacchus
env_file=$conf_dir/env
stack=${1:-$(sed -n 's/^BACCHUS_STACK=//p' "$env_file" 2>/dev/null || true)}
stack=${stack:-bacchus-$(hostname -s)}

aws cloudformation deploy --stack-name "$stack" --template-file "$here/template.yaml" \
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset

output() {
  aws cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
repository=$(output Repository)
user=$(output UserName)

if [[ -e $env_file ]]; then
  echo "$env_file already exists; not creating another access key."
  exit 0
fi

# Existing keys belong to an earlier install or another (possibly lost) machine.
# A user can have at most two.
for key in $(aws iam list-access-keys --user-name "$user" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  read -rp "Delete existing access key $key of $user? [y/N] " answer || answer=
  if [[ $answer == [yY]* ]]; then
    aws iam delete-access-key --user-name "$user" --access-key-id "$key"
  fi
done

echo "Creating an access key for $user, writing $env_file"
creds=$(aws iam create-access-key --user-name "$user" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
read -r key_id secret <<<"$creds"
umask 077
mkdir -p "$conf_dir"
cat >"$env_file" <<EOF
BACCHUS_STACK=$stack
RESTIC_REPOSITORY=$repository
AWS_ACCESS_KEY_ID=$key_id
AWS_SECRET_ACCESS_KEY=$secret
EOF

echo "Done. Next: bacchus init"
