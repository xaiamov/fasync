# fasync – fanotify‑driven async sync for huge storage

**fasync** is a lightweight, event‑driven synchronization tool for multi‑terabyte filesystems.  
Instead of recursively scanning directories, it uses Linux **fanotify** with `FAN_MARK_FILESYSTEM` to watch the whole mount and reports only the changes that happen inside your source directory.

This makes it ideal for large storage partitions (several TB) where files are added, modified and removed frequently – and where scanning the entire tree would be prohibitively slow.

---

## How it works

- A small C program (`fawatch`) watches the entire filesystem (or mount) for `CREATE`, `DELETE` and `MODIFY` events using Linux fanotify.
- Events are filtered to the source directory you specify.
- A bash script collects the event paths, waits for a configurable delay (default 60 seconds) to batch changes, then calls `rsync` **only for the changed files** – no full scans, no recursion.
- **Delayed deletion:** When `-D <seconds>` is given, `DELETE` events are not applied immediately. Instead, the paths are logged to a hidden file inside the source directory. After the specified delay, the script checks if the file still exists on the source; if it has been permanently removed, it is added to the next `rsync` batch, so the target side deletes it as well. This provides a safety net against accidental deletions.
- **Event logging:** By default, every event is printed to stdout. Use `-q` to suppress this output.

---

## Installation

```bash
git clone https://github.com/xaiamov/fasync
cd fasync
make
```
(If you want to install system‑wide, run `sudo make install`.)

## Usage

```bash
./fasync.sh /path/to/source user@host:/path/to/target [options]
```
- The source path must be on a filesystem that supports fanotify (any modern Linux filesystem).
- The target can be any local or remote path that rsync understands.

## Options

| Option           | Description |
|------------------|-------------|
| `-d <seconds>`   | Delay in seconds to accumulate events before invoking `rsync`. Default: `60`. |
| `-D <seconds>`   | Delayed deletion – wait this many seconds before actually removing a deleted file on the target. Default: `0` (immediate). |
| `-q`             | Quiet mode – do not print each file event to stdout. (Errors and summary messages are still shown.) |

## Examples

### Basic usage with 2‑minute batching and immediate deletion

```bash
./fasync.sh /data/source backup-host:/data/target -d 120
```

### Deletion with a 24‑hour grace period

```bash
./fasync.sh /data/source backup-host:/data/target -d 60 -D 86400
```
Here, files that are deleted on the source will be removed from the target only after 24 hours, unless they are re‑created in the meantime.

### Quiet mode (no per‑event output)

```bash
./fasync.sh /data/source backup-host:/data/target -q
```

## Features

**Currently implemented**

- File creation (FAN_CREATE)
- File deletion (FAN_DELETE)
- File modification (FAN_MODIFY)
- File renaming (FAN_MOVED_FROM / FAN_MOVED_TO)
- Attribute changes (FAN_ATTRIB)
- Delayed deletion – configurable grace period for safe removal
- Quiet mode for minimal log output

**Planned**

- Directory deletion events
- More flexible filtering (include/exclude patterns)

## How delayed deletion works
When `-D <seconds>` is set to a value greater than 0, the script does not immediately add deleted files to the `rsync` batch. Instead:

1. The absolute path of each deleted file is written to a hidden log file inside the source directory: `.deleted.<hash>.log`.
2. Every minute (configurable via `delete_check_interval` in the script) the log is checked.
3. For each entry that has exceeded the grace period (`-D`), the script verifies if the file still exists on the source.
4. If the file is gone, its relative path is added to the main event buffer, so that the next rsync run will remove it from the target.
5. Entries that are still within the grace period remain in the log for future checks.

The log file itself is synchronised to the target side as a regular file, so the delayed‑deletion state is preserved even if the source machine restarts.

## SSH multiplexing (recommended for remote sync)

When syncing to a remote host over SSH, enable connection multiplexing to avoid repeated authentication overhead. Add the following to your `~/.ssh/config`:

```
Host *
    ControlMaster auto
    ControlPath ~/tmp/%r@%h:%p
    ServerAliveInterval 60
    ControlPersist 10m
```

This keeps one SSH connection open for up to 10 minutes, dramatically reducing latency for frequent `rsync` runs.

## Why fanotify instead of inotify?

- **inotify** requires recursive watches on every subdirectory – impossible when you have millions of directories.
- **fanotify** with FAN_MARK_FILESYSTEM watches the whole mount with a single mark, regardless of how many files or directories exist.
- `fasync` only reacts to actual changes and never walks the directory tree.

## Requirements

- Linux kernel ≥ 5.1.
- The source directory must reside on a mountable filesystem (e.g. a dedicated partition or external drive). A plain subdirectory of `/` will work only if you mark the whole root filesystem and then filter; performance is still fine.

## License

This project is licensed under the MIT License – feel free to use, modify, and distribute it.