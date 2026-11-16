# codebergup.sh

Upload folders to [Codeberg](https://codeberg.org) from the command line. It is the Codeberg twin of `gitup.sh`:
each folder becomes one repository, big files go to Git LFS automatically, and an existing `.git` or an
existing repository with the same name is handled for you.

The difference: **Codeberg has no `gh auth login`.** You just give your **username and password** and
`codebergup.sh` does the rest.

```bash
bash codebergup.sh --all -y          # every subfolder → its own Codeberg repo
bash codebergup.sh                   # the current folder only
bash codebergup.sh --folder A B C    # specific folders
```

It asks for the username and password once per run (the password is hidden while you type).

## Quick start

1. Put `codebergup.sh` in the directory that holds your project folders.
2. Run `bash codebergup.sh --all -y`.
3. Type your Codeberg username and password. Done.

For scripts, skip the prompts:

```bash
CODEBERG_USER=alice CODEBERG_PASSWORD='my password' bash codebergup.sh --all -y
```

The script can be renamed to anything (for example `cbpush.sh`); it never uploads itself when it sits inside the
folder being uploaded. A copy in a *subfolder* is uploaded normally.

## Two-factor authentication

If your account uses 2FA, Codeberg does not accept the password for API/git access. Use an **access token**
instead of the password (type it at the password prompt, or set `CODEBERG_TOKEN`):

1. Open <https://codeberg.org/user/settings/applications>
2. Create a token with permissions **repository → read and write** and **user → read**
3. Paste it where the password would go

Tokens also work for accounts without 2FA, and you can revoke them at any time.

## What it does for each folder

| Situation | What happens |
|---|---|
| Folder has no `.git` | `git init`, branch `main`, commit, create the repository on Codeberg, push |
| Folder has someone else's `.git` | The old `.git` is **moved** (not deleted) to `<parent>/.codebergup-backups/`, a fresh one is created, then the same as above |
| Folder was made by `codebergup.sh` or `gitup.sh` earlier | Updated in place: new commit, normal push |
| A repo with that name already exists on your account | Your folder's content is put on top of its history (plain fast-forward push, **no force push**). Files that no longer exist in the folder are removed from the repo; the old history stays |
| The old `.git` pointed at someone else's repo | The remote is switched to **your** repo with the folder's name |
| Codeberg rate-limits repository creation | It waits (using Codeberg's `Retry-After`, otherwise 60 s, doubling) and retries |
| Files over 25 MB | Stored with Git LFS automatically (`CODEBERGUP_LFS_MB`) |
| A file over 100 MB is already in old commits | The branch history is rewritten once into LFS; the old history stays under `refs/codebergup-backup/` |

Roughly the same as typing, per folder:

```bash
git remote add codeberg https://codeberg.org/<you>/<folder>.git
git branch -M main
git push -u codeberg main
```

…but with all the cases above handled, and without ever putting your password in a command or a URL.

## Options

| Option | Meaning |
|---|---|
| `-u`, `--user NAME` | Codeberg username (otherwise asked, or `CODEBERG_USER`) |
| `--folder DIR…` | Process these folders. `--folder all` = every direct subfolder |
| `--all` | Same as `--folder all` |
| `-y`, `--yes` | Don't ask questions (installs, confirmations) |
| `-n`, `--dry-run` | Only show what would happen; nothing is contacted or changed |
| `--private` | New repositories are private (default: **public**) |
| `--public` | New repositories are public (the default) |
| `--safe` | Never overwrite or rewrite anything: keep the existing `.git`, stop if Codeberg has different history |
| `--keep-git` | Keep a folder's existing `.git` instead of replacing it |
| `--fresh` | Always replace a folder's `.git` with a fresh one (even one made by this tool) |
| `-h`, `--help` | Help |

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CODEBERG_USER`, `CODEBERG_PASSWORD`, `CODEBERG_TOKEN` | – | Log in without prompts |
| `CODEBERGUP_YES=1` | – | Same as `--yes` |
| `CODEBERGUP_SKIP="a b"` | – | Extra folder names to skip in `--all` mode |
| `CODEBERGUP_LFS_MB` | 25 | Files bigger than this use Git LFS (max 100) |
| `CODEBERGUP_LFS_MAX_MB` | 1536 | Files bigger than this are not uploaded at all |
| `CODEBERGUP_RETRIES` | 3 | Attempts for network operations |
| `CODEBERGUP_RATE_RETRIES` | 4 | Waits when Codeberg rate-limits creation (0 = don't wait) |
| `CODEBERGUP_RATE_WAIT` | 60 | First wait in seconds (doubles each time) |
| `CODEBERGUP_CREATE_DELAY` | 2 | Pause between repository creations |
| `CODEBERGUP_PKG_MANAGER` | auto | Force `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`, `xbps-install` or `brew` |
| `CODEBERGUP_NO_DEFAULT_IGNORE=1` | – | Don't add default ignores to repos without a `.gitignore` |
| `CODEBERGUP_HOST` | `codeberg.org` | Another Forgejo/Gitea server (**untested**) |

## Security: what happens to your password

- It is typed with echo off, kept only in the script's memory, and **never** written to disk.
- It is **never** placed in a command line (so it does not show up in `ps`), in a remote URL, or in `.git/config`.
  The API client reads it from a pipe; `git` gets it from a private helper that only exists for the run
  (mode 700, in a temporary folder that is removed when the script ends, even on errors).
- Saved git credential helpers on your machine are ignored for these commands, so an old stored password
  can't override what you typed.
- Nothing is stored for later runs. You can use a revocable access token instead of your real password.
- Your commits use `username@noreply.codeberg.org` unless you already have a git identity configured.

New repositories are **public** by default. The script warns before uploading files that look like secrets
(`.env`, `*.pem`, `id_rsa`, …); use `--private` for private repos.

## Codeberg's limits (good to know)

- Codeberg asks you to request extra resources before using more than **750 MiB of Git storage** or
  **1.5 GiB of LFS + packages + attachments** together. `codebergup.sh` warns when a folder is that big.
  Requests: <https://codeberg.org/Codeberg-e.V./requests>
- Private repositories get **100 MB** by default.
- **100 repositories** per account by default.
- Codeberg is for free/libre projects; read its Terms of Use before uploading things that aren't.

## Using it together with gitup.sh (GitHub)

Both scripts can work on the same folder. `codebergup.sh` uses a remote called **`codeberg`**, `gitup.sh` uses
**`origin`**, and each one treats a repository made by the other as its own (no `.git` replacement, no mixing
up of remotes). So running both scripts after each change keeps GitHub and Codeberg in sync.

## Troubleshooting

| Message | Meaning / fix |
|---|---|
| `Codeberg rejected that username/password` | Wrong login, or a 2FA account: use an access token |
| `Could not reach codeberg.org` | No internet, or Codeberg is down/busy; re-run later |
| `Codeberg is temporarily blocking repository creation` | Rate limit on Codeberg's side. Wait, then re-run only the failed folders (the summary prints the command). Folders whose repo already exists are not affected |
| `repository limit` | Your account hit the repository limit; request more (link in the message) |
| `No write access to this repository` | The remote belongs to someone else, or is archived |
| `A branch protection or push rule blocks this push` | Change it in the repository's Settings → Branches |
| `something was too big` | Lower `CODEBERGUP_LFS_MB` (for example 10) so more files use LFS |

Every failed folder gets a one-line reason in the summary, plus a ready-to-paste command to re-run just those folders.

## Requirements

`git`, `curl` and `jq` (the script offers to install them with your package manager: apt, dnf, yum, pacman,
zypper, apk, xbps or Homebrew). `git-lfs` is installed the same way when a big file needs it. Works on any
Linux distribution and on macOS (including the stock bash 3.2).

## Not tested against the real codeberg.org

`codebergup.sh` was tested against a local imitation of Codeberg's (Forgejo) API and git/LFS servers, not
against the live site. The exact wording of some Codeberg error replies (two-factor, rate limits, repository
limit) is assumed, so a message might fall back to a generic one — the underlying behaviour (stop, explain,
re-run hint) still applies. If you see something wrong, run it on one small folder first.
