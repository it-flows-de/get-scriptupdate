# get-scriptupdate

Bash script for servers that updates all Git-cloned scripts below one directory to the
newest signed release tag. It runs unattended (cron, as root). Patch and minor releases
are applied automatically, major releases are only reported.

## How it works

Every direct subdirectory of `SCRIPTS_ROOT` is treated as one script. For each one the
script:

- skips it if it is not a Git clone, has local changes to tracked files (including the
  executable bit) or is not checked out on a release tag
- fetches the tags and looks for the newest release tag (`vMAJOR.MINOR.PATCH`) of the
  **same major version**; a newer major release is only logged as a warning
- verifies the signature of that tag against the `allowed_signers` file and checks that
  the signed tag carries the same name as the ref; only then it checks out the commit
- rolls back to the previous tag if the checkout fails
- never goes back to an older version

Git runs as the owner of each script directory, not as root, and ignores global and
system Git config. The script updates itself last; the new version is used from the next
run. Local changes, unsigned or wrongly signed tags never lead to an update, they are
logged and reported through the exit code.

## Requirements

- Debian (current release), Bash, Git 2.34 or newer, `ssh-keygen`, `runuser`, `flock`,
  `timeout`
- Runs as root
- A file with the public keys that may sign release tags (`ALLOWED_SIGNERS_FILE`),
  owned by `root:root` and not writable by group or others
- Network access to the Git remote of the scripts (public repositories over HTTPS, no
  credentials)

## Installation

See [INSTALL.md](INSTALL.md).

## Configuration

Copy `get-scriptupdate.config.example` to `get-scriptupdate.config` next to the script,
edit it and set permissions to `660`. The example file is commented and documents every
parameter. The config is never committed to Git. All parameters have defaults, nothing is
required.

| Parameter | Block | Meaning | Default |
|---|---|---|---|
| `CONFIG_VERSION` | - | Config format version, must match the script | `1` |
| `EXCLUDE_DIRS` | optional | Directory names below `SCRIPTS_ROOT` that are ignored completely, empty = none | empty |
| `SCRIPTS_ROOT` | default | Directory with one Git clone per script | `/usr/local/scripts` |
| `ALLOWED_SIGNERS_FILE` | default | Public keys allowed to sign release tags | `/etc/get-scriptupdate/allowed_signers` |
| `REMOTE_NAME` | default | Git remote the tags are fetched from | `origin` |
| `GIT_TIMEOUT_SECONDS` | default | Maximum duration of one fetch | `120` |
| `LOG_FILE` | default | Log file, rotated by logrotate | `/var/log/get-scriptupdate/get-scriptupdate.log` |
| `MARKER_FILE` | default | Marker file for monitoring | `<script directory>/last-successful` |
| `LOCK_FILE` | default | Lock file against parallel runs | `/run/lock/get-scriptupdate.lock` |

A directory without `.git` is reported as skipped. Add it to `EXCLUDE_DIRS` if it must
not be handled.

## Usage

```
get-scriptupdate.sh [--dry-run] [--only NAME] [--help]
```

| Option | Meaning |
|---|---|
| `--dry-run` | Fetch the tags and report what would be updated, change no script directory and write no marker file |
| `--only NAME` | Process only the directory `NAME` (ignores `EXCLUDE_DIRS`), no marker file is written |
| `--help` | Show the help |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK: all scripts up to date or updated |
| 1 | General error (for example not run as root) |
| 2 | Wrong option or unknown directory for `--only` |
| 3 | Config error (missing file, wrong permissions, wrong `CONFIG_VERSION`, invalid values, unsafe `allowed_signers`) |
| 4 | Another instance is already running |
| 5 | Attention needed: a script was skipped (no `.git`, local changes, not on a release tag) or a major update is pending |
| 6 | At least one update failed (fetch, signature not verified, checkout) |

## Monitoring

After a completely clean run (exit code 0, not a dry run, not `--only`) the script writes
the marker file `last-successful` with a timestamp. Monitoring checks the age of this
file and raises an alarm when it gets too old. No marker file means: something was
skipped, a major update is waiting, an update failed or the job does not run. The log
shows which one.
