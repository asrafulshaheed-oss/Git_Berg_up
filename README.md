# gitup.sh

Upload local folders to GitHub with one command.

`gitup.sh` checks that `git` and the GitHub CLI (`gh`) are installed and that you are logged in, then turns a folder into a GitHub repository named after the folder, commits everything, and pushes it. Run it again later and it simply updates the repository. Big files are handled automatically with Git LFS.

```bash
cd ~/Downloads/MyProject
./gitup.sh
```

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Options](#options)
- [Environment variables](#environment-variables)
- [What happens to each folder](#what-happens-to-each-folder)
- [Repository names](#repository-names)
- [`--all` mode](#--all-mode)
- [Large files and Git LFS](#large-files-and-git-lfs)
- [The script never uploads itself](#the-script-never-uploads-itself)
- [Fresh `.git`, account switching and overwriting](#fresh-git-account-switching-and-overwriting)
- [GitHub rate limits](#github-rate-limits)
- [Safety features](#safety-features)
- [Dependencies and login](#dependencies-and-login)
- [Which GitHub account? (y / n / q)](#which-github-account-y--n--q)
- [Output, summary and exit codes](#output-summary-and-exit-codes)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

---

## Features

- **One command.** Run `./gitup.sh` inside a project and it does the rest.
- **Checks and installs what is missing.** Detects `git` and `gh`, asks before installing, and starts `gh auth login` if you are not logged in.
- **Fresh `.git`, automatically.** A folder's old `.git` is replaced by a new one (the old one is moved to a backup, not deleted), then gitup does the equivalent of `git remote add origin …`, `git branch -M main`, `git push -u origin main`.
- **Follows your current GitHub login.** The remote is always `<your current account>/<folder name>`, even if the old `.git` pointed at another account.
- **Overwrites by default.** If that repository already exists, the folder's content is put on top of its history, so GitHub ends up matching your folder (a modified file, a deleted file, anything). Nothing is force-pushed. `--safe` turns this off.
- **Patient with GitHub.** If GitHub throttles repository creation (secondary rate limit), gitup waits and retries instead of failing.
- **Login happens on the spot.** Not logged in? `gh auth login` starts immediately, and the upload continues as soon as you finish.
- **Asks which GitHub account to use.** Logged in already? It shows the account name and asks `y` (upload with it), `n` (log in to another account with `gh auth login`, then continue) or `q` (quit). See [Which GitHub account?](#which-github-account-y--n--q).
- **One folder, many folders, or all folders.** Each folder becomes its own repository, named after the folder.
- **Large files just work.** Files over 25 MB go to Git LFS automatically, up to GitHub's per-file cap.
- **Honest results.** A failed folder is reported with the reason on its summary line, plus a ready-to-paste command to re-run just the failed folders. The exit code reflects it.
- **Works everywhere.** Any Linux distribution (apt, dnf/yum, pacman, zypper, apk, xbps) and macOS (Homebrew), including macOS's stock bash 3.2.
- **Rename it freely.** The script recognises itself by its real path, so `gitpush.sh`, `up`, or any other name works.

## Requirements

| Needed | Notes |
| --- | --- |
| bash 3.2 or newer | Preinstalled on Linux and macOS. Do not run it with `sh`. |
| `git` | Installed for you if missing (you are asked first). |
| `gh` (GitHub CLI) | Installed for you if missing (you are asked first). |
| `git-lfs` | Only needed when a file is larger than 25 MB. Installed on request. |
| Internet access and a GitHub account | |

Windows is supported only through WSL.

## Installation

Pick whichever layout suits you.

**A. Next to the things you upload (recommended).** Put `gitup.sh` in the folder that holds your projects, or inside a single project's root.

```bash
cd ~/Downloads            # the folder that contains your projects
chmod +x gitup.sh         # once; or always run it as: bash gitup.sh
```

```text
~/Downloads/
├── gitup.sh
├── Meshtalk/
├── NotesApp/
└── Website/
```

**B. Install once, use anywhere.**

```bash
mkdir -p ~/.local/bin
cp gitup.sh ~/.local/bin/gitup.sh
chmod +x ~/.local/bin/gitup.sh
# make sure ~/.local/bin is on your PATH, then from any folder:
gitup.sh
```

Do not `source gitup.sh`. The script refuses to run that way.

## Usage

| Command | What it does |
| --- | --- |
| `./gitup.sh` | Process the **current directory**. |
| `./gitup.sh --folder Meshtalk` | Process one folder. |
| `./gitup.sh --folder A B C` | Process several folders, one repository each. |
| `./gitup.sh --folder all` | Process **every direct subfolder** of the current directory. |
| `./gitup.sh --all` | Same as `--folder all`. |
| `./gitup.sh Meshtalk NotesApp` | Shorthand: folder names without `--folder` also work. |
| `./gitup.sh --all -y` | Same as `--all`, without asking for confirmation. |
| `./gitup.sh --all --private` | New repositories are created as private. |
| `./gitup.sh --all --safe` | Never overwrite: stop on a folder whose GitHub repository has different history. |
| `./gitup.sh --all --dry-run` | Only show which folders and repository names would be used. |
| `GITUP_SKIP="scratch tmp" ./gitup.sh --all` | Also skip folders named `scratch` and `tmp`. |
| `./gitup.sh --folder ./all` | Process a folder that is literally named `all`. |

Typical sessions:

```bash
# 1. A single project: open a terminal inside it
cd ~/Downloads/MyProject
./gitup.sh

# 2. Later, after editing or adding files: run the same command again
./gitup.sh

# 3. Upload a folder that sits next to the script
cd ~/Downloads
./gitup.sh --folder Meshtalk

# 4. Upload several folders at once
./gitup.sh --folder Meshtalk NotesApp Website

# 5. Upload everything, check first what would happen
./gitup.sh --all --dry-run
./gitup.sh --all
```

Folder names that start with `-` must be written as `./-name`. Everything after a lone `--` is treated as a folder name.

## Options

| Option | Meaning |
| --- | --- |
| `--folder DIR [DIR…]`, `--folder=DIR` | Folders to process. `all` expands to every direct subfolder. |
| `--all` | Process every direct subfolder of the current directory. |
| `-y`, `--yes` | Don't ask questions: confirmations, dependency installs, the "upload secrets anyway?" prompt. The [GitHub account question](#which-github-account-y--n--q) is still asked on a terminal. |
| `-n`, `--dry-run` | List the folders and repository names, then exit. Nothing is installed, created or pushed, and no login is needed. |
| `--private` | Create **new** repositories as private. |
| `--public` | Create new repositories as public. This is already the default. |
| `--keep-git` | Keep each folder's existing `.git` as it is instead of replacing it. |
| `--fresh` | Replace the `.git` of every folder, even one that gitup created earlier. |
| `--safe` (alias `--no-force`) | Never overwrite or rewrite anything: implies `--keep-git`, stops when GitHub has different history, never rewrites history. Cannot be combined with `--fresh`. |
| `-h`, `--help` | Show the built-in help. |

> **New repositories are public by default.** Use `--private` if you do not want that. The setting only affects repositories the script creates; it never changes the visibility of an existing repository.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `GITUP_YES` | `0` | `1` is the same as `--yes`. |
| `GITUP_SKIP` | empty | Extra folder names to skip in `--all` mode. Separate with spaces or commas. |
| `GITUP_LFS_MB` | `25` | Files larger than this are stored with Git LFS. Maximum `100`. |
| `GITUP_LFS_MAX_MB` | `2048` | Files larger than this are **not uploaded** (GitHub's LFS per-file cap). |
| `GITUP_RETRIES` | `3` | Attempts for network operations (push, LFS upload). |
| `GITUP_RATE_RETRIES` | `4` | How many times to wait and retry when GitHub throttles repository creation. `0` = don't wait. |
| `GITUP_RATE_WAIT` | `60` | Seconds to wait the first time; doubles each time (max 600). |
| `GITUP_CREATE_DELAY` | `3` | Seconds to pause between two repository creations, to avoid triggering the throttle. |
| `GITUP_PKG_MANAGER` | auto | Force a package manager: `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`, `xbps-install`, `brew`. |
| `GITUP_NO_DEFAULT_IGNORE` | unset | Set to any value to disable the [default ignores](#default-ignores). |
| `GITUP_NO_ACCOUNT_PROMPT` | `0` | `1` = don't ask which GitHub account to use; just use the one that is logged in. |
| `NO_COLOR` | unset | Disable coloured output. |
| `GH_TOKEN` | unset | A GitHub token; `gh` uses it instead of an interactive login (the account question is then skipped, because the token decides the account). |

Example: `GITUP_LFS_MB=50 GITUP_RETRIES=5 ./gitup.sh --folder Meshtalk`

## What happens to each folder

For every folder, in order:

1. **Repository.**
   - A folder with an existing `.git` that gitup did **not** create: the `.git` is moved to `<parent folder>/.gitup-backups/<folder>-<date-time>.git` and a new repository is created on branch `main` (even if your `init.defaultBranch` is `master`). Your files are not touched.
   - A `.git` that gitup created on an earlier run (it carries a marker, `gitup.managed`): kept and simply updated, so GitHub gets one new commit per run. `--fresh` replaces it anyway; `--keep-git` keeps any `.git`.
   - No `.git`: a new repository is created. If the folder sits *inside* another git repository, it still gets its own repository and the outer one is untouched.
   - If the old `.git` pointed at a GitHub repository of **your current account**, that same repository name is kept (so a folder uploaded as `Notes` is not suddenly pushed to a second repository named after the folder). Anything else is replaced by `<your-username>/<folder-name>`.
2. **Safety checks.** A detached `HEAD`, or a merge, rebase or cherry-pick in progress, stops the folder with a clear message.
3. **Git identity.** If `user.name` or `user.email` is not configured, your GitHub name and your GitHub `…@users.noreply.github.com` address are set for that repository only.
4. **Local excludes.** The running script and the [default ignores](#default-ignores) are added to `.git/info/exclude`. That file is local and is never committed.
5. **Large files.** Files over the LFS threshold are set up for Git LFS. See [Large files and Git LFS](#large-files-and-git-lfs).
6. **Stage and commit.** Everything git would normally add is staged (`.gitignore` is respected). The commit message is `Initial commit` for a new repository and `Update from gitup.sh YYYY-MM-DD HH:MM:SS` afterwards. With nothing new, no commit is made, but any unpushed commits are still pushed.
7. **Remote.**
   - A kept (`--keep-git` or gitup-made) repository: its remote (`origin`, or the first one it has) is checked against GitHub. If your current login can push to it, it is used as it is. If it belongs to another account, does not exist, or cannot be written with your current login, it is **switched** to `<your-username>/<folder-name>` (`git remote set-url`).
   - A fresh repository: the remote is `<your-username>/<folder-name>`. If that repository exists, it is used; if not, it is created (public unless you passed `--private`). See [GitHub rate limits](#github-rate-limits).
   - Remotes that are not on github.com are used as they are. Any other answer from GitHub (network down, bad token) stops the folder instead of guessing.
   - The clone URL uses your `gh` protocol setting (HTTPS or SSH).
8. **Existing history on GitHub.** In a fresh repository, if GitHub already has the branch, the script fetches it and adds one commit on top whose content is exactly your folder (files you no longer have are removed; if nothing differs, nothing is added). See [below](#fresh-git-account-switching-and-overwriting).
9. **Branch name.** For a kept repository on a new or switched remote, a `master` branch is renamed to `main` (unless `main` exists). After pushing a fresh repository, or to a new or switched remote, GitHub's default branch is set to the branch you pushed.
10. **Big files in old history.** Only for kept repositories; see [Large files and Git LFS](#large-files-and-git-lfs).
11. **Push.** LFS objects are uploaded first (when LFS is in use), then `git push -u <remote> <branch>`. Temporary network failures are retried (`GITUP_RETRIES`). Only if GitHub still says the remote branch has different history (a kept repository with its own diverged history) is the push forced, with the previous remote tip printed.

A folder with nothing to upload (empty, or everything ignored) is reported as skipped, not failed.

### What the script changes on your machine

- Inside each folder: `.git/` (new, or replaced), `.git/info/exclude`, and, only when LFS is used, `.gitattributes` and repo-local LFS hooks and filters.
- Next to your project folders: `.gitup-backups/` holding each replaced `.git` (a hidden folder; `--all` ignores it and it is never uploaded). If the parent folder cannot be written to, backups go to `~/.cache/gitup-backups/`. To reclaim the space later, delete the backups you no longer need.
- Repo-local `user.name` / `user.email`, only when you have none configured.
- The remote URL, when a remote pointed at another account or a missing repository (and the stale remote-tracking branches of that old remote).
- The local branch name: a fresh repository always starts on `main`; a kept `master` branch is renamed to `main` for a new or switched remote.
- A backup ref `refs/gitup-backup/…`, when old history had to be rewritten for Git LFS.
- Globally, `gh auth setup-git` makes `gh` the git credential helper for GitHub (it edits `~/.gitconfig`; this is how HTTPS pushes get authenticated).
- A temporary file in `$TMPDIR` (or `/tmp`) that is removed when the script exits.

Your working files are never modified or deleted. An old `.git` is moved, never deleted, so its history and any unpushed commits survive in the backup (use `git --git-dir=<backup> log` to look inside; copy it back as `.git` to restore it).

## Repository names

The repository name is the folder name, cleaned up to what GitHub accepts:

| Folder | Repository |
| --- | --- |
| `Meshtalk` | `Meshtalk` |
| `My Project (v2)` | `My-Project-v2` |
| `notes.git` | `notes` |

- Spaces become `-`; characters other than letters, digits, `.`, `_` and `-` are removed; a trailing `.git` is dropped; the name is cut to 100 characters.
- A name that is empty after cleaning (for example one written only in Bangla or Arabic script) or that is only dots cannot be used. That folder fails with an explanation; other folders continue. Rename the folder and run again.
- When the name had to be changed, you are told.

## `--all` mode

`--all` (or `--folder all`) turns every **direct subfolder** of the current directory into its own repository.

Skipped automatically, with a notice:

- hidden folders (names starting with `.`)
- symbolic links
- empty folders
- common build and dependency folders: `node_modules`, `__pycache__`, `.venv`, `venv`, `env`, `virtualenv`, `dist`, `build`, `out`, `target`, `bin`, `obj`, `.idea`, `.vscode`, `.vs`, `.history`, `.cache`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `vendor`, `.next`, `.nuxt`, `.svelte-kit`, `.turbo`
- anything listed in `GITUP_SKIP`

Naming a folder explicitly (`--folder build`) **always** processes it; the skip list only applies when expanding `all`.

If more than 5 folders are found, the script lists them and asks `Proceed? [Y/n]`. Use `-y` to skip the question.

All folders are checked **before** anything is uploaded: if one of the names you typed does not exist, nothing is uploaded at all. The same directory given twice (`Meshtalk`, `./Meshtalk`, `Meshtalk/`) is processed once.

A failure in one folder never stops the others; you get a summary at the end.

If you have a folder literally named `all`, `--folder all` means "every subfolder". Use `--folder ./all` for just that one.

## Large files and Git LFS

GitHub rejects any normal git file larger than 100 MiB and warns above 50 MiB. For bigger files it offers [Git LFS](https://git-lfs.com). The script handles this for you:

| File size | What happens |
| --- | --- |
| up to `GITUP_LFS_MB` (25 MB) | Committed normally. |
| over `GITUP_LFS_MB`, up to `GITUP_LFS_MAX_MB` (2048 MB) | Tracked with Git LFS, one `.gitattributes` entry per file, and uploaded with the push. |
| over `GITUP_LFS_MAX_MB` | **Not uploaded.** A warning names the file; everything else in the folder still goes up. |

Details:

- Only files git would really add are considered. Anything in `.gitignore` is left alone, so a huge ignored file never triggers LFS.
- File names with spaces or characters like `[`, `*` or `?` are handled.
- Running again does not create duplicate rules. A file that is already tracked is reported as such.
- If `git-lfs` is missing, you are asked whether to install it.
  - Declined, and no file is over 100 MB: the files are committed normally, with a warning.
  - Declined, and some file is over 100 MB: the folder is refused, because GitHub would reject the push. Nothing is created on GitHub.
- GitHub's per-file LFS cap is 2 GB on Free and Pro, 4 GB on Team and 5 GB on Enterprise Cloud. If your plan allows more, raise `GITUP_LFS_MAX_MB`.
- GitHub limits the LFS storage and bandwidth included with each account. Many large files can use it up; see your GitHub billing page. To keep mid-size files out of LFS, raise `GITUP_LFS_MB` (up to 100).
- GitHub also limits a single push (about 2 GB). Because large files go through LFS, normal pushes stay small.

**A big file that is already in your commit history** (committed in the past without LFS, even if deleted later) would make GitHub reject the push. With the default fresh `.git` this cannot happen: the new repository only contains today's files, and big ones go through LFS. It matters only for repositories you keep (`--keep-git`, `--safe`, or one gitup made earlier). Before pushing, the script checks the history that is not on GitHub yet and, unless you use `--safe`:

1. saves the old tip as `refs/gitup-backup/<branch>-<timestamp>`,
2. runs `git lfs migrate import --include-ref=refs/heads/<branch> --above=100MiB`, which moves those files into LFS and rewrites this branch's history,
3. pushes the rewritten branch.

The backup ref keeps the old history on your machine. Free the space later with `git update-ref -d <ref> && git gc --prune=now`. With `--safe`, the folder fails and the exact `git lfs migrate` command is printed.

A file that is still an LFS *pointer* in your folder (a clone made without Git LFS installed) cannot be uploaded from a fresh repository because its real content is not on this machine. Run `git lfs pull` in that folder first, or use `--keep-git`.

## The script never uploads itself

The script that is *currently running* is excluded from the upload, but only when it lives **inside the repository being pushed**. Any other file, even one with the same name, is uploaded normally. The script recognises itself by its real path, so renaming it is fine.

| Situation | Result |
| --- | --- |
| `gitup.sh` is in the project root and you run `./gitup.sh` | Not uploaded. |
| You rename it to `gitpush.sh` and run `./gitpush.sh` | Not uploaded. |
| `gitup.sh` is in `~/Downloads` and you run `./gitup.sh --all`; the projects are subfolders | Nothing to exclude; the script is outside every repository. |
| A project has its **own, different** `gitup.sh` somewhere inside it (for example `Meshtalk/gitup.sh` or `Meshtalk/sub/gitup.sh`) | **Uploaded**; it is not the running script. |
| The running script sits in a subfolder of the project (`tools/gitup.sh`, started from the project root) | Not uploaded; it is still the running script. |
| It is installed on your `PATH` (for example `~/.local/bin`) | Nothing to exclude. |

If an earlier run had already committed the running script, it is removed from the repository index and not uploaded again. An old-style rule that excluded the bare file name everywhere is cleaned up automatically.

## Fresh `.git`, account switching and overwriting

gitup is meant to be automatic, so it prefers to finish the upload over stopping to ask.

**Fresh `.git`.** For a folder whose `.git` gitup did not create, the old `.git` is moved to `.gitup-backups/` (nothing is deleted) and a new repository is created: `git init`, `git branch -M main`, add, commit, `git remote add origin …`, `git push -u origin main`. This removes every problem an old `.git` can bring along: a remote on another account, a deleted repository, diverged history, big files buried in old commits, a half-finished merge. Because gitup marks the repository it creates, later runs just add one commit per run.

**You switched GitHub accounts.** The folder is uploaded to `<your-username>/<folder-name>` on the account you are logged in with now. Nothing is touched on the old account.

**A repository with the same name already exists on your account.** The folder's content is put on top of the history that is there:

```text
[INFO]  GitHub already has 'main' — putting this folder's content on top of it.
```

gitup fetches the branch and adds one commit whose files are exactly your folder's, so a changed `kama.sh` is updated, a file you deleted locally is removed, and the result is an ordinary fast-forward push. The previous state stays in GitHub's history, nothing is force-pushed, and if the content is already identical nothing is added at all. Only the pushed branch changes; other branches and the repository's settings are untouched. If the repository only has a different default branch (say `master`), `main` is pushed as a new branch and made the default.

**Fallback.** If gitup cannot read the existing branch, or you use `--keep-git` on a repository with its own diverged history, GitHub rejects a normal push. gitup then force-pushes and prints the commit that was replaced:

```text
[WARN]  The remote branch 'main' has different history — overwriting it with this folder's content.
[WARN]    (previous remote tip: 48c8a4f8c91014f92025c340299a44ba096c5cb2)
```

**Want a seat belt?** Use `--safe`: your `.git` is kept, nothing is overwritten or rewritten, and a folder whose GitHub repository has different history stops with the exact merge command.

## GitHub rate limits

GitHub limits how fast an account can create repositories (a "secondary rate limit"). The message looks like *"You have exceeded a secondary rate limit and have been temporarily blocked from content creation"*. It is GitHub throttling the account, not a problem with your folders, and brand-new accounts hit it quickly. gitup deals with it like this:

- It pauses `GITUP_CREATE_DELAY` seconds (default 3) between two creations.
- When GitHub says no, it waits `GITUP_RATE_WAIT` seconds (default 60), retries, and doubles the wait each time, up to `GITUP_RATE_RETRIES` times (default 4, about 15 minutes in total). Ctrl-C stops it.
- If the block does not lift, that folder fails with a short message, and the remaining folders that need a new repository fail immediately instead of each waiting again. Folders whose repository already exists are not affected and still upload.
- The summary ends with a command that re-runs only the failed folders. Run it again after a few minutes to an hour.

Set `GITUP_RATE_RETRIES=0` if you would rather not wait at all.

## Safety features

### Secrets prompt

Before committing, the script looks at the files being **newly added**. If any look like credentials (`.env`, `.env.*`, `id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`, `*.pem`, `*.p12`, `*.pfx`, `*.key`; examples such as `.env.example` are ignored), it lists them and asks `Upload them anyway? [y/N]`.

- Answer `n` (the default), or run without a terminal: that folder is skipped and nothing is staged.
- `-y` skips the question and uploads.
- Remember that **new repositories are public by default**. For credentials, put them in `.gitignore` or use `--private`.

This is a filename check only. It cannot find secrets written inside ordinary files.

### Default ignores

If a repository has **no `.gitignore` at all**, the script keeps these out for that repository (written to `.git/info/exclude`, local only, never committed): `.DS_Store`, `Thumbs.db`, `node_modules/`, `__pycache__/`, `*.pyc`, `.venv/`. If you have a `.gitignore`, it is respected and this does not apply. Set `GITUP_NO_DEFAULT_IGNORE=1` to turn this off.

### Nested repositories

A subfolder that has its own `.git` is added by git as an empty link, so its files are **not** uploaded. The script warns you when that happens.

## Dependencies and login

**Missing `git` or `gh`:** the script lists what is missing and asks `Install them now using your package manager?` You may then be asked for your password (`sudo`, or `doas`). `-y` answers yes automatically. Without a terminal and without `-y` it explains and stops.

| Package manager | Systems | Package for `gh` |
| --- | --- | --- |
| `apt-get` | Debian, Ubuntu, Linux Mint, Pop!_OS, … | `gh` |
| `dnf` / `yum` | Fedora, RHEL, CentOS, Rocky, Alma, Amazon Linux | `gh` |
| `pacman` | Arch, Manjaro, Omarchy, EndeavourOS, … | `github-cli` |
| `zypper` | openSUSE, SUSE | `gh` |
| `apk` | Alpine | `github-cli` |
| `xbps-install` | Void | `github-cli` |
| `brew` | macOS, Linuxbrew | `gh` |

- On Debian/Ubuntu, RHEL-family and openSUSE systems whose own repositories lack `gh`, the script adds GitHub's official package repository and retries.
- On Arch, if pacman cannot find the package, run `sudo pacman -Syu` and try again.
- **macOS:** `git` comes with the Command Line Tools (`xcode-select --install`) or Homebrew. Homebrew itself is not installed for you; get it from <https://brew.sh>.

**Login:** the script asks GitHub who you are (`gh api user`). If you are logged in it shows the account and asks whether to use it (see [Which GitHub account?](#which-github-account-y--n--q)). If that fails because you are not logged in, `gh auth login` starts immediately, you follow its prompts, and the upload continues as soon as the login is finished. That needs a terminal. In automation, log in beforehand or set `GH_TOKEN`. If GitHub is merely unreachable (no network), the script says so instead of asking you to log in.

## Which GitHub account? (y / n / q)

If you have several GitHub accounts, the one `gh` is logged in to decides where everything is uploaded. So, when a login already exists, the script shows it and asks before it touches anything:

```text
[INFO]  GitHub account currently logged in:  rahul-call
    Do you want to upload to this GitHub account?
      y = yes, continue with rahul-call
      n = no, log in to another account (gh auth login), then continue
      q = quit
    Your choice [y/n/q]:
```

| Answer | What happens |
| --- | --- |
| `y` | Continues with that account. |
| `n` | Runs `gh auth login` so you can log in to another account. When the login finishes, the upload continues with the **new** account. (If the login is cancelled or fails, you are asked again.) |
| `q` | Quits right away. Nothing has been created, committed or pushed. |

- Only an explicit `y`, `n` or `q` counts. A bare Enter or any other text asks again, so a stray keypress can't upload to the wrong account. `Ctrl-D` quits.
- **Not logged in at all?** There is no question: `gh auth login` starts immediately, then the upload continues.
- The question is asked **even with `-y`** (that option answers confirmations and installs, not "which account?"), as long as you are at a terminal.
- It is **not** asked without a terminal (cron, pipes, CI), when `GH_TOKEN` / `GITHUB_TOKEN` is set (the token decides the account), or when `GITUP_NO_ACCOUNT_PROMPT=1`. In those cases the logged-in account is used.
- `--dry-run` never asks, since it does not log in.
- After switching, folders that were uploaded with the old account are repointed to the new account's repository of the same name, as described in [Fresh `.git`, account switching and overwriting](#fresh-git-account-switching-and-overwriting).
- `gh` can keep several logins at once; `gh auth status` lists them and `gh auth switch` changes the active one without logging in again. The `n` answer is for adding a new one.

## Output, summary and exit codes

Messages are tagged `[INFO]`, `[ OK ]`, `[WARN]` and `[FAIL]` and are written to standard error. After the last folder you get a summary:

```text
[INFO]  Summary
[ OK ]  Meshtalk  →  https://github.com/yourname/Meshtalk  (new .git, created)
[ OK ]  Notes  →  https://github.com/yourname/Notes  (new .git, existing repo, content replaced, history kept)
[WARN]  scratch  →  skipped (nothing to upload)
[FAIL]  Tools  →  failed: GitHub rejected your credentials (logged in as yourname). Try:  gh auth login   and   gh auth setup-git
[FAIL]  1 of 4 folder(s) failed.
[INFO]  After fixing the cause, re-run only the failed folders:
    ./gitup.sh --folder Tools
```

The text in parentheses lists what happened: `new .git` (the old one was replaced), `created`, `existing repo`, `content replaced, history kept`, `already identical on GitHub`, `switched from <old-owner/repo>` and `overwrote existing remote content` (kept repositories only), `moved big files in history to LFS`, or `updated` for an ordinary push.

| Exit code | Meaning |
| --- | --- |
| `0` | Every folder was uploaded or skipped. |
| `1` | At least one folder failed, or the command line was invalid. |
| `130` | Interrupted with Ctrl-C. |

## Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `GitHub is temporarily blocking repository creation… (rate limit)` | GitHub-side throttling; see [GitHub rate limits](#github-rate-limits). Wait, then run the printed re-run command. |
| `Could not move the old .git out of the way` | The folder or its parent is read-only. Fix the permissions, or use `--keep-git`. |
| `Replacing the existing .git with a fresh one…` | Not an error: your old `.git` was saved to the path shown. |
| `HEAD is detached` | Check out a branch first: `git switch main`. |
| `A merge/rebase/cherry-pick is in progress` | Finish or abort it, then re-run. |
| `The remote branch has different history (--safe mode…)` | You used `--safe`. Re-run without it, or merge: `git pull --no-rebase --allow-unrelated-histories origin <branch>`. |
| `The remote branch has different history and gitup could not overwrite it` | Usually branch protection or a repository rule; see the next rows. |
| `--fresh and --safe cannot be combined` / `--fresh and --keep-git…` | Pick one. |
| `Branch protection blocks this push` | Turn the protection off in the repository's Settings → Branches, then re-run. |
| `The GitHub repository is archived` | Unarchive it under Settings → Danger Zone, then re-run. |
| `Remote 'origin' (…) does not exist / can't be written to… switching it` | Not an error (kept repositories only): gitup moved the remote to your current account. |
| `Files in this folder's commit history are over 100 MB…` | Without `--safe` gitup fixes this itself (see [Large files](#large-files-and-git-lfs)). With `--safe`, run the printed `git lfs migrate import` command. |
| `your login lacks the 'workflow' scope` | You are pushing `.github/workflows`. Run `gh auth refresh -h github.com -s workflow`. |
| `GitHub blocked the push (secret scanning…)` | A real secret was detected. Remove it from the files and the commit, then re-run. |
| `LFS storage/bandwidth quota exceeded` | Buy more LFS data, delete old LFS objects, or raise `GITUP_LFS_MB`. |
| `GitHub rejected your credentials` | Run `gh auth login` and `gh auth setup-git`. |
| `The remote repository was not found` | A non-GitHub remote, or one deleted while pushing. Check `git remote -v`. |
| `GitHub CLI is not logged in and there is no terminal` | Log in first with `gh auth login`, or set `GH_TOKEN`. |
| `You appear to be logged in, but GitHub could not be reached` | Network or proxy problem. Check your connection and re-run. |
| `Cannot derive a valid GitHub repository name` | Rename the folder using letters, digits, `.`, `_` or `-`. |
| `Could not check GitHub for …` | Usually no network or an expired token. Try `gh auth status`. |
| `Too large for GitHub … NOT uploaded` | That file is over `GITUP_LFS_MAX_MB`. Split it, host it elsewhere, or add it to `.gitignore`. |
| `Nothing was uploaded. Fix the folder name(s)` | One of the folders you typed does not exist. Check the spelling. |
| `gitup.sh needs bash` | You ran it with `sh`. Use `./gitup.sh` or `bash gitup.sh`. |

## Limitations

- GitHub.com only (not GitHub Enterprise Server).
- Repositories are created under your personal account, not under an organisation.
- Folder names that contain no letters or digits from `A-Z`, `a-z`, `0-9` cannot become repository names.
- Only the current branch is pushed; tags are not.
- Existing GitHub repositories are never changed in visibility, name or settings. The only exceptions are the pushed branch's content and, when you start a fresh repository or switch the remote, the default branch.
- A fresh `.git` starts without your old local history (it is in the backup). If that history was pushed, it comes back from GitHub: gitup builds on top of what GitHub has. Commits you never pushed live only in the backup.
- Only the pushed branch is considered when putting your content on top of GitHub's history. Tags and other branches of the old `.git` are not carried over.
- Overwriting is per branch: only the branch being pushed is replaced.
- A fresh repository keeps the old remote only when it is on your current account. A repository on another account that you can push to (a collaborator repository) is not reused; the folder goes to a repository under your own account. Use `--keep-git` to push to such a repository.
- Each folder is its own repository. Subfolders that have their own `.git` are not merged in.

## Codeberg

Want the same for [Codeberg](https://codeberg.org)? See `codebergup.sh` and `CODEBERGUP_README.md`: you give it your
Codeberg username and password (no `gh`-style login needed). Both scripts can work on the same folder:
`gitup.sh` uses the remote `origin`, `codebergup.sh` uses `codeberg`, and each treats a repository made by the
other as its own.
