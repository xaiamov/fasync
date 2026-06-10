# fasync – fanotify‑driven async sync for huge storage

**fasync** is a lightweight, event‑driven synchronization tool for multi‑terabyte filesystems.  
Instead of recursively scanning directories, it uses Linux **fanotify** with `FAN_MARK_FILESYSTEM` to watch the whole mount and reports only the changes that happen inside your source directory.

This makes it ideal for large storage partitions (several TB) where files are added, modified and removed frequently – and where scanning the entire tree would be prohibitively slow.

## How it works

- A small C program watches the entire filesystem (or mount) for `CREATE`, `DELETE` and `MODIFY` events.
- Events are filtered to the source directory you specify.
- A bash script collects the event paths, waits for a configurable delay (default 60 seconds) to batch changes, then calls `rsync` **only for the changed files** – no full scans, no recursion.

## Installation

```bash
git clone https://github.com/xaiamov/fasync
cd fasync
make
```

## Usage

```bash
./fasync.sh /path/to/source user@host:/path/to/target [options]
```
The source path must be on a filesystem that supports fanotify (any modern Linux filesystem).
The target can be any local or remote path that rsync understands.

## Options

| Option | Description |
|--------|-------------|
| `-d`   | Delay in seconds to accumulate events before invoking `rsync`. Default: `60`. |
| `-q`   | Quiet mode – do not print each file path. |

Example with a custom delay of 5 minutes:

bash
./fasync.sh /data/source backup-host:/data/target -d 300

## Features

**Currently implemented**

- File creation (`FAN_CREATE`)
- File deletion (`FAN_DELETE`)
- File modification (`FAN_MODIFY`)
- File renaming (`FAN_MOVED_FROM | FAN_MOVED_TO`)
- Attribute changes (`FAN_ATTRIB`)

**Planned**

- Directory deletion events

## SSH multiplexing (recommended for remote sync)

When syncing to a remote host over SSH, enable connection multiplexing to avoid repeated authentication overhead. Add the following to your `~/.ssh/config`:

```text
Host *
    ControlMaster auto
    ControlPath ~/tmp/%r@%h:%p
    ServerAliveInterval 60
    ControlPersist 10m
```
This keeps one SSH connection open for up to 10 minutes, dramatically reducing latency for frequent rsync runs.

## Why fanotify instead of inotify?

inotify requires recursive watches on every subdirectory – impossible when you have millions of directories.
fanotify with FAN_MARK_FILESYSTEM watches the whole mount with a single mark, regardless of how many files or directories exist.
fasync only reacts to actual changes and never walks the directory tree.

## Requirements

Linux kernel ≥ 5.1.
The source directory must reside on a mountable filesystem (e.g. a dedicated partition or external drive). A plain subdirectory of / will work only if you mark the whole root filesystem and then filter; performance is still fine.

## License

This project is licensed under the MIT License – feel free to use, modify, and distribute it.
