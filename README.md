# bacchus

Automatic, encrypted backups of selected home directories to your own S3 bucket,
using [restic](https://restic.net), systemd user timers, and a small
CloudFormation stack. Written for an Ubuntu laptop; it should work on any Linux
desktop with systemd.

## How it works

- **Daily**, the directories listed in `~/.config/bacchus/includes` are backed
  up, skipping anything matching `~/.config/bacchus/excludes`. Keeping the
  lists out of the repo keeps your folder names off GitHub. **Weekly**, old snapshots are
  dropped (keeping 7 daily, 4 weekly, 12 monthly and 5 yearly), unused data is
  pruned, and the repository is checked. Runs missed while the machine was asleep
  or off happen when it wakes. A failed run is retried for about an hour, then
  you get a desktop notification.
- **Two restic keys** open the repository:
  - your **passphrase**, which you choose and remember. It isn't stored anywhere,
    and it's what gets you into the backups from a new machine.
  - a random **machine password** in `~/.config/bacchus/machine-password`,
    which the timers use.
- **On AWS**, a CloudFormation stack ([`aws/template.yaml`](aws/template.yaml))
  named `bacchus-<hostname>` creates an S3 bucket and an IAM user that can use
  only that bucket. The machine holds that user's access key, never your own AWS
  credentials. The bucket is versioned and the key can't delete old versions or
  change bucket settings, so anything deleted or overwritten through it, whether
  by mistake, by malware, or by whoever has a stolen laptop, can be recovered for
  550 days (about 18 months).
- restic encrypts everything before upload, so AWS only ever stores encrypted data.

| Path | What |
|---|---|
| `includes.example` | starting point for your list of directories to back up, relative to `$HOME` |
| `excludes.example` | starting point for your list of restic exclude patterns (see `restic help backup`) |
| `bin/bacchus` | runs restic with this machine's repository and credentials, plus the `init`, `backup` and `prune` commands |
| `systemd/` | timers for the daily backup and the weekly prune and check; failure notification |
| `aws/template.yaml` | CloudFormation template: the bucket and the backup-only IAM user |
| `aws/setup.sh` | deploys the stack and writes this machine's access key |
| `install.sh` | links `bacchus` into `~/.local/bin`, installs the systemd units, creates your lists from the examples, and installs restic if needed |

Each machine also has, outside the repo, `~/.config/bacchus/` (mode 700):

- `includes`, `excludes`: your lists, created by `install.sh`. They're backed up
  along with your files, so a full restore brings them back.
- `env`: stack name, repository URL, and the backup user's access key, written by `aws/setup.sh`
- `machine-password`: written by `bacchus init`

## Requirements

- Linux with systemd, on x86-64 or ARM64; bash, curl, bzip2, openssl and notify-send
- restic 0.18 or newer; `install.sh` installs 0.19.1 if needed
- For setup and recovery only: AWS CLI v2 and credentials that can manage
  CloudFormation, S3 and IAM, such as from `aws login`

## Setup

1. Get the code:

   ```sh
   git clone https://github.com/<you>/bacchus.git ~/code/bacchus
   cd ~/code/bacchus
   ```

2. `./install.sh`. Besides linking `bacchus` and installing the units, this
   downloads restic 0.19.1 into `~/.local/bin`, checking it against the checksum in
   `install.sh`, unless that version or newer is already installed. (Ubuntu
   24.04's own restic package is too old.)
3. Edit `~/.config/bacchus/includes` and `~/.config/bacchus/excludes`.
4. Create the AWS resources and this machine's access key:

   ```sh
   aws login
   aws/setup.sh
   ```

5. `bacchus init`, and choose your passphrase.
6. Run the first backup and look at it: `bacchus backup`, then `bacchus snapshots`.
7. Turn on the timers:

   ```sh
   systemctl --user enable --now bacchus.timer bacchus-prune.timer
   ```

## Everyday use

```sh
bacchus snapshots                  # list backups
bacchus backup --dry-run -v        # what the next backup would add
systemctl --user list-timers 'bacchus*'
journalctl --user -u 'bacchus*'    # logs
```

Any restic command works through `bacchus`, with the repository and
credentials filled in.

## Recovery

### Restore files (machine still works)

```sh
bacchus ls latest "$HOME/Documents"
bacchus restore latest --target ~/restore --include "$HOME/Documents/taxes"
bacchus mount ~/mnt     # every snapshot as folders; Ctrl-C to unmount
```

`--target ~/restore` recreates the full path under it, e.g.
`~/restore/home/<you>/Documents/taxes`. `--target /` puts files back where they were,
overwriting the current versions.

### Machine lost, stolen or broken

You need your passphrase, AWS credentials that can manage IAM (e.g. `aws login`),
and this repository.

On the replacement machine:

1. Follow setup steps 1 and 2. Leave the lists alone; step 6 restores yours.
2. Find the old machine's stack:

   ```sh
   aws cloudformation describe-stacks --query "Stacks[?starts_with(StackName, 'bacchus-')].StackName"
   ```

3. `aws/setup.sh bacchus-<old hostname>`. When it asks, delete the old
   machine's access key, so the old machine can no longer reach the bucket.
4. `bacchus init`, and enter your passphrase. This gives the new machine its
   own key to the repository.
5. Remove the old machine's restic key: `bacchus key list`, then
   `bacchus key remove <ID>` for the `bacchus` key with the old hostname
   (not the one marked `*`, which is the new machine's).
6. Restore: `bacchus snapshots`, then `bacchus restore latest --target /`.
   This also puts back your `includes` and `excludes`. If your username has
   changed, restore to `--target ~/restore` and move the files into place.
7. To carry on backing up from the new machine into the same bucket, turn on the
   timers (setup step 7). Snapshots are grouped by hostname, so the old machine's
   latest snapshots are kept as well.

### Forgotten passphrase (machine still works)

The machine password still opens the repository, so set a new passphrase and
remove the old one:

```sh
bacchus key add            # type the new passphrase
bacchus key list           # the old passphrase is the older key with your username
bacchus key remove <ID>
```

If the machine and the passphrase are both lost, the backups can't be decrypted
by anyone.

### Replace the access key

```sh
aws login
rm ~/.config/bacchus/env
aws/setup.sh [STACK]           # answer y to delete the old key
```

Give `STACK` if it isn't `bacchus-<hostname>`.

## Making changes

- `~/.config/bacchus/includes`, `excludes`: used from the next backup on.
- Retention: the `--keep-*` options in `bin/bacchus`.
- systemd units: re-run `./install.sh`.
- `aws/template.yaml`: `aws login`, then `aws/setup.sh`. This updates the stack and
  leaves the access key alone.
- restic: `restic self-update`, which checks the release signature itself.

## Uninstall

```sh
systemctl --user disable --now bacchus.timer bacchus-prune.timer
rm ~/.local/bin/bacchus ~/.config/systemd/user/bacchus*
rm -r ~/.config/bacchus
rm ~/.local/bin/restic        # if install.sh installed it and nothing else uses it
```

To remove the AWS side, delete the user's access keys
(`aws iam list-access-keys --user-name <stack>`, then `aws iam delete-access-key`),
then `aws cloudformation delete-stack --stack-name <stack>`. The bucket and the
backups in it are kept on purpose. Empty and delete the bucket in the S3 console
if you really want them gone.

## Cost

S3 Standard is about $0.023 per GB per month in us-east-1, so a few GB of backups
cost cents a month, plus a little for requests. Data that restic deletes is billed
for 550 more days as old versions, so you pay for about 18 months' worth of whatever
prune deletes; for a repository of mostly documents that's cents a month. Downloading data
for a restore costs about $0.09 per GB.
