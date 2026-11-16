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
- [Safety features](#safety-features)
- [Dependencies and login](#dependencies-and-login)
- [Output, summary and exit codes](#output-summary-and-exit-codes)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

---

## Features

- **One command.** Run `./gitup.sh` inside a project and it does the rest.
- **Checks and installs what is missing.** Detects `git` and `gh`, asks before installing, and starts `gh auth login` if you are not logged in.
- **New or existing repositories.** No `.git` yet: one is created. Existing `.git`: it is updated and pushed.
- **One folder, many folders, or all folders.** Each folder becomes its own repository, named after the folder.
- **Large files just work.** Files over 25 MB go to Git LFS automatically, up to GitHub's per-file cap.
- **Honest results.** A failed push is reported as a failure, with the likely fix, and the exit code reflects it.
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
| `-y`, `--yes` | Don't ask questions: confirmations, dependency installs, the "upload secrets anyway?" prompt. |
| `-n`, `--dry-run` | List the folders and repository names, then exit. Nothing is installed, created or pushed, and no login is needed. |
| `--private` | Create **new** repositories as private. |
| `--public` | Create new repositories as public. This is already the default. |
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
| `GITUP_PKG_MANAGER` | auto | Force a package manager: `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`, `xbps-install`, `brew`. |
| `GITUP_NO_DEFAULT_IGNORE` | unset | Set to any value to disable the [default ignores](#default-ignores). |
| `NO_COLOR` | unset | Disable coloured output. |
| `GH_TOKEN` | unset | A GitHub token; `gh` uses it instead of an interactive login. |

Example: `GITUP_LFS_MB=50 GITUP_RETRIES=5 ./gitup.sh --folder Meshtalk`

## What happens to each folder

For every folder, in order:

1. **Repository.** If the folder has no `.git`, `git init` creates one on branch `main` (or your `init.defaultBranch`). If the folder sits *inside* another git repository, it still gets its own separate repository, and the outer one is left untouched. An existing `.git` is reused as it is, and its branch name is kept (for example `master`).
2. **Safety checks.** A detached `HEAD`, or a merge, rebase or cherry-pick in progress, stops the folder with a clear message.
3. **Git identity.** If `user.name` or `user.email` is not configured, your GitHub name and your GitHub `…@users.noreply.github.com` address are set for that repository only.
4. **Local excludes.** The running script and the [default ignores](#default-ignores) are added to `.git/info/exclude`. That file is local and is never committed.
5. **Large files.** Files over the LFS threshold are set up for Git LFS. See [Large files and Git LFS](#large-files-and-git-lfs).
6. **Stage and commit.** Everything git would normally add is staged (`.gitignore` is respected). The commit message is `Initial commit` the first time and `Update from gitup.sh YYYY-MM-DD HH:MM:SS` afterwards. With nothing new, no commit is made, but any unpushed commits are still pushed.
7. **Remote.**
   - If the repository already has a remote (`origin`, or the first one it has), that remote is used.
   - Otherwise the script looks for `<your-username>/<folder-name>` on GitHub. If it exists, it is attached. If it does not, it is created, public unless you passed `--private`. Any other answer from GitHub (network down, bad token) stops the folder instead of guessing.
   - The clone URL uses your `gh` protocol setting (HTTPS or SSH).
8. **Push.** LFS objects are uploaded first (when LFS is in use), then `git push -u <remote> <branch>`. Temporary network failures are retried (`GITUP_RETRIES`). The script **never force-pushes**.

A folder with nothing to upload (empty, or everything ignored) is reported as skipped, not failed.

### What the script changes on your machine

- Inside each folder: `.git/` (if new), `.git/info/exclude`, and, only when LFS is used, `.gitattributes` and repo-local LFS hooks and filters.
- Repo-local `user.name` / `user.email`, only when you have none configured.
- Globally, `gh auth setup-git` makes `gh` the git credential helper for GitHub (it edits `~/.gitconfig`; this is how HTTPS pushes get authenticated).
- A temporary file in `$TMPDIR` (or `/tmp`) that is removed when the script exits.

Your files are never modified or deleted.

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

**A big file that is already in your commit history** (committed in the past without LFS) cannot be fixed by tracking it now. The push fails and the script prints the fix. If the repository was never pushed and nobody else has a copy:

```bash
git lfs migrate import --everything --above=100MB
```

This rewrites history, so do not use it on a repository others have cloned.

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

### No force pushes

If GitHub says the remote has commits you do not have, the script stops and prints the command to merge them. Nothing on GitHub is overwritten.

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

**Login:** if `gh` is not logged in to github.com, the script starts `gh auth login` and you follow its prompts. That needs a terminal. In automation, log in beforehand or set `GH_TOKEN`.

## Output, summary and exit codes

Messages are tagged `[INFO]`, `[ OK ]`, `[WARN]` and `[FAIL]` and are written to standard error. After the last folder you get a summary:

```text
[INFO]  Summary
[ OK ]  Meshtalk  →  https://github.com/yourname/Meshtalk
[WARN]  scratch  →  skipped (nothing to upload)
[FAIL]  বাংলা  →  failed
[FAIL]  1 of 3 folder(s) failed.
```

| Exit code | Meaning |
| --- | --- |
| `0` | Every folder was uploaded or skipped. |
| `1` | At least one folder failed, or the command line was invalid. |
| `130` | Interrupted with Ctrl-C. |

## Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `HEAD is detached` | Check out a branch first: `git switch main`. |
| `A merge/rebase/cherry-pick is in progress` | Finish or abort it, then re-run. |
| `The remote branch has commits that this folder doesn't have` | Merge first: `git pull --no-rebase --allow-unrelated-histories origin <branch>`, then re-run. |
| `The GitHub repo already exists and has a different history` | A repository with the folder's name already exists on your account. Rename the local folder, or merge as above. |
| `A file over 100 MB is stored in the commit history without Git LFS` | See [Large files](#large-files-and-git-lfs): `git lfs migrate import --everything --above=100MB`. |
| `your login lacks the 'workflow' scope` | You are pushing `.github/workflows`. Run `gh auth refresh -h github.com -s workflow`. |
| `GitHub blocked the push (secret scanning…)` | A real secret was detected. Remove it from the files and the commit, then re-run. |
| `LFS storage/bandwidth quota exceeded` | Buy more LFS data, delete old LFS objects, or raise `GITUP_LFS_MB`. |
| `GitHub rejected your credentials` | Run `gh auth login` and `gh auth setup-git`. |
| `The remote repository was not found` | Check `git remote -v`; the repository may have been deleted or renamed. |
| `No terminal available for login` | Log in first with `gh auth login`, or set `GH_TOKEN`. |
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
- Existing repositories are never changed in visibility, name or settings.
- Each folder is its own repository. Subfolders that have their own `.git` are not merged in.
