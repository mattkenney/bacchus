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
| `aws/setup.sh` | deploys the stack and writes this machine's access key; `install.sh` runs it on the first install |
| `install.sh` | sets up everything on this machine; safe to re-run |
| `uninstall.sh` | removes it again, asking before deleting anything on AWS |

`install.sh` copies everything it needs out of the checkout, so you can move or
delete the checkout afterwards:

- `~/.local/bin/bacchus`
- `~/.local/lib/bacchus/restic`: bacchus's own restic, separate from any other
- `~/.local/lib/bacchus/uninstall.sh`
- `~/.config/systemd/user/bacchus*`

Each machine also has `~/.config/bacchus/` (mode 700):

- `includes`, `excludes`: your lists, created by `install.sh`. They're backed up
  along with your files, so a full restore brings them back.
- `env`: stack name, repository URL, and the backup user's access key, written by `aws/setup.sh`
- `machine-password`: written by `bacchus init`

## Requirements

- Linux with systemd, on x86-64 or ARM64; bash, curl, bzip2, openssl and notify-send
- For the first install, recovery and uninstall only: AWS CLI v2 and credentials
  that can manage CloudFormation, S3 and IAM, such as from `aws login`

## Setup

1. Get the code:

   ```sh
   git clone https://github.com/<you>/bacchus.git ~/code/bacchus
   cd ~/code/bacchus
   ```

2. `aws login`, or get other AWS credentials that can manage CloudFormation, S3
   and IAM.
3. `./install.sh`. This:
   - downloads restic 0.19.1 into `~/.local/lib/bacchus`, checking it against the
     checksum in `install.sh`
   - copies `bacchus` and the systemd units into place
   - creates `~/.config/bacchus/includes` and `excludes` from the examples
   - creates the CloudFormation stack `bacchus-<hostname>` and this machine's
     access key, using `aws/setup.sh`
   - creates the repository, asking you to choose your passphrase
   - turns on the timers
4. Edit `~/.config/bacchus/includes` and `excludes` before the first scheduled
   backup, around midnight. To try them out: `bacchus backup`, then
   `bacchus snapshots`.

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

1. Follow setup steps 1 and 2.
2. Find the old machine's stack:

   ```sh
   aws cloudformation describe-stacks --query "Stacks[?starts_with(StackName, 'bacchus-')].StackName"
   ```

3. `./install.sh bacchus-<old hostname>`. When it asks, delete the old machine's
   access key, so the old machine can no longer reach the bucket. Then enter your
   passphrase, which gives the new machine its own key to the repository. Leave
   the lists it creates alone; step 5 restores yours.
4. Remove the old machine's restic key: `bacchus key list`, then
   `bacchus key remove <ID>` for the `bacchus` key with the old hostname
   (not the one marked `*`, which is the new machine's).
5. Restore: `bacchus snapshots`, then `bacchus restore latest --target /`.
   This also puts back your `includes` and `excludes`. If your username has
   changed, restore to `--target ~/restore` and move the files into place.

From then on the new machine backs up into the same bucket. Snapshots are grouped
by hostname, so the old machine's latest snapshots are kept as well.

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
- `bin/bacchus`, systemd units: re-run `./install.sh` to copy them in again. After
  the first install it doesn't touch AWS, so it needs no credentials.
- `aws/template.yaml`: `aws login`, then `aws/setup.sh`. This updates the stack and
  leaves the access key alone.
- restic: `bacchus self-update` runs restic's own updater, which checks the release
  signature. Re-running `install.sh` keeps the newer version.

## Uninstall

`./uninstall.sh`, or `~/.local/lib/bacchus/uninstall.sh` if the checkout is gone,
stops and removes the timers, units, `bacchus` command and its restic, then asks
whether to also delete:

- the AWS stack, its IAM user and access keys (needs `aws login`). This stops
  backups from every machine using that stack.
- `~/.config/bacchus`

The bucket and the backups in it are always kept. To delete them for good, empty
and delete the bucket in the S3 console.

## Cost

S3 Standard is about $0.023 per GB per month in us-east-1, so a few GB of backups
cost cents a month, plus a little for requests. Data that restic deletes is billed
for 550 more days as old versions, so you pay for about 18 months' worth of whatever
prune deletes; for a repository of mostly documents that's cents a month. Downloading data
for a restore costs about $0.09 per GB.
