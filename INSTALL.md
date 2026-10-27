# Installation: get-scriptupdate

Automated Bash script (cron, runs as root). It updates every Git-cloned script below
`SCRIPTS_ROOT` to the newest signed release tag of the same major version. Major
releases are only reported.

All commands are meant to be pasted into **one terminal session**. The variables from
step 0 and step 3 only exist in that session. If you open a new terminal, repeat
step 0 and run `source "${CONFIG_FILE}"` again.

## 0. Variables

```bash
SCRIPT_HOME=/usr/local/scripts
SCRIPT_NAME=get-scriptupdate
SCRIPT_DIR="${SCRIPT_HOME}/${SCRIPT_NAME}"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.config"
TAG=v1.0.0
```

`SCRIPT_HOME` is only used in this guide. The script itself finds its own
directory at runtime.

## 1. Prerequisites

```bash
sudo apt install git openssh-client
git --version
```

Git must be 2.34 or newer (`ssh-keygen`, `runuser`, `flock` and `timeout` are part
of the standard Debian system).

The file with the allowed signing keys must exist, root-owned and not writable by
others. It is set up as described in your internal howtos:

```bash
ls -l /etc/get-scriptupdate/allowed_signers
```

Expected: `-rw-r--r-- 1 root root`.

## 2. Script directory and files

The base directory belongs to the normal user, so no `sudo` is needed below it. All
script directories under it should belong to that user: the script runs Git as the
owner of each directory, never as root.

```bash
sudo mkdir -p "${SCRIPT_HOME}"
sudo chown "$USER": "${SCRIPT_HOME}"
```

Note: a script that is later run as root must not live in a directory that other
users can write to.

### Variant A: release path (signed tag)

```bash
git clone "https://github.com/it-flows-de/${SCRIPT_NAME}.git" "${SCRIPT_DIR}"
cd "${SCRIPT_DIR}"
git -c gpg.ssh.allowedSignersFile=/etc/get-scriptupdate/allowed_signers verify-tag "${TAG}" && git checkout "${TAG}"
```

The checkout only runs if the signature check succeeds. The executable bit comes
from the repository, no `chmod` is needed.

### Variant B: development path (only before the first release)

Create the files and copy the content from the ZIP with an editor of your choice:

```bash
mkdir -p "${SCRIPT_DIR}"
cd "${SCRIPT_DIR}"
touch "${SCRIPT_NAME}.sh" "${SCRIPT_NAME}.config.example" .gitignore README.md INSTALL.md
chmod 755 "${SCRIPT_NAME}.sh"
```

## 3. Config

```bash
cd "${SCRIPT_DIR}"
cp "${SCRIPT_NAME}.config.example" "${SCRIPT_NAME}.config"
vi "${CONFIG_FILE}"
chmod 660 "${CONFIG_FILE}"
source "${CONFIG_FILE}"
echo "SCRIPTS_ROOT=${SCRIPTS_ROOT} EXCLUDE_DIRS=(${EXCLUDE_DIRS[*]:-})"
echo "ALLOWED_SIGNERS_FILE=${ALLOWED_SIGNERS_FILE} LOG_FILE=${LOG_FILE} MARKER_FILE=${MARKER_FILE}"
```

The config is sourced by bash and is therefore code. It must never be committed to
Git (`.gitignore` excludes `*.config`).

**Which directories are updated?** Every direct subdirectory of `SCRIPTS_ROOT` is
treated as one script. A directory without `.git` is reported as skipped and keeps the
marker file from being written, so a script that was not converted yet is noticed in
the monitoring. Directories that must not be touched (not a script, or a Git clone
that you do not want to update automatically) are listed in `EXCLUDE_DIRS`:

```bash
EXCLUDE_DIRS=("some-directory" "another-directory")
```

Names are exact directory names, no wildcards and no paths. An excluded directory
can still be updated by hand with `--only NAME`.

## 4. Directories

The log directory is created by hand. The script does not create it.

```bash
sudo mkdir -p "$(dirname "${LOG_FILE}")"
```

## 5. Secrets

Not needed: the script reads public repositories over HTTPS and has no credentials.

## 6. logrotate

Weekly rotation, keeping 12 logs:

```bash
sudo tee "/etc/logrotate.d/${SCRIPT_NAME}" >/dev/null <<LOGROTATE
${LOG_FILE} {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 660 root adm
}
LOGROTATE
sudo chown root:root "/etc/logrotate.d/${SCRIPT_NAME}"
sudo chmod 644 "/etc/logrotate.d/${SCRIPT_NAME}"
sudo logrotate -d "/etc/logrotate.d/${SCRIPT_NAME}"
```

The last command is a dry run: it shows what would happen and finds syntax errors.

## 7. Test

Help:

```bash
"${SCRIPT_DIR}/${SCRIPT_NAME}.sh" --help
```

Dry run (fetches the tags, changes nothing in the script directories, writes no
marker file):

```bash
sudo "${SCRIPT_DIR}/${SCRIPT_NAME}.sh" --dry-run
sudo tail -n 30 "${LOG_FILE}"
```

Check the result: each script directory appears with `up to date`, `would update`,
`skipped` or an error. Exit code 5 means that something was skipped or a major update
is pending (see the log), exit code 6 means that an update failed.

Real run and marker file:

```bash
sudo "${SCRIPT_DIR}/${SCRIPT_NAME}.sh"; echo "exit code: $?"
sudo tail -n 30 "${LOG_FILE}"
cat "${MARKER_FILE}"
```

The marker file only exists after a run that was completely clean (exit code 0).

Test of a single script (no marker file is written after this):

```bash
sudo "${SCRIPT_DIR}/${SCRIPT_NAME}.sh" --only some-directory
```

Error case: wrong permissions on the config (expected: error message, exit code 3):

```bash
chmod 664 "${CONFIG_FILE}"
sudo "${SCRIPT_DIR}/${SCRIPT_NAME}.sh"; echo "exit code: $?"
chmod 660 "${CONFIG_FILE}"
```

## 8. Cron

The job runs in the root crontab, not at midnight (logrotate runs then). The
redirect catches errors that occur before the config is loaded; the log path appears
twice on purpose.

```bash
( sudo crontab -l 2>/dev/null; echo "17 3 * * * ${SCRIPT_DIR}/${SCRIPT_NAME}.sh >> ${LOG_FILE} 2>&1" ) | sudo crontab -
sudo crontab -l
```

## 9. Monitoring

In n-sight, add a check on the age of the marker file (value of `MARKER_FILE`, by
default `last-successful` in the script directory). The job runs daily, so an alarm
after two to three days without a new marker file is a good start. A missing or old
marker file means: a script was skipped, a major update is waiting, an update failed,
or the job does not run. The log tells which one.

## Updating this script

`get-scriptupdate` is itself a Git clone below `SCRIPTS_ROOT` and updates itself at the
end of a run; the new version is used from the next run. A new major release is only
reported (see the log), then the config usually has to be adapted by hand.

## Troubleshooting

| Exit code | Meaning | What to check |
|---|---|---|
| 0 | OK | - |
| 1 | General error | Is the script run as root? Read the log |
| 2 | Wrong option or `--only` name | Run with `--help`, directory exists below `SCRIPTS_ROOT` |
| 3 | Config error | Config exists, permissions are `660`, `CONFIG_VERSION` matches, `allowed_signers` is owned by `root:root` and not writable by group or others, `SCRIPTS_ROOT` exists |
| 4 | Already running | Another run is active, try again later |
| 5 | Attention needed | Log shows `skipped` (local changes, not on a release tag, no `.git`) or a pending major update |
| 6 | Update failed | Log shows the script and the reason: fetch (network), signature not verified, checkout (rolled back) |
