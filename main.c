#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fanotify.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int fan, mount_fd;
    char buf[4096];
    ssize_t buflen;
    struct fanotify_event_metadata *metadata;
    struct fanotify_event_info_fid *fid;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s /dir\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    // Resolve the watched directory to an absolute canonical path
    char watch_path[PATH_MAX + 1];
    if (realpath(argv[1], watch_path) == NULL) {
        perror("realpath");
        exit(EXIT_FAILURE);
    }

    mount_fd = open(argv[1], O_DIRECTORY | O_RDONLY);
    if (mount_fd == -1) {
        perror(argv[1]);
        exit(EXIT_FAILURE);
    }

    fan = fanotify_init(FAN_CLASS_NOTIF | FAN_REPORT_FID | FAN_REPORT_DFID_NAME,
                        O_RDONLY | O_LARGEFILE);
    if (fan == -1) {
        perror("fanotify_init");
        exit(EXIT_FAILURE);
    }

    if (fanotify_mark(fan, FAN_MARK_ADD | FAN_MARK_FILESYSTEM,
                      FAN_CREATE | FAN_DELETE | FAN_MODIFY |
                      FAN_MOVED_FROM | FAN_MOVED_TO | FAN_ATTRIB,
                      AT_FDCWD, argv[1]) == -1) {
        perror("fanotify_mark");
        exit(EXIT_FAILURE);
    }

    int is_root = (strcmp(watch_path, "/") == 0);
    size_t watch_len = strlen(watch_path);

    for (;;) {
        buflen = read(fan, buf, sizeof(buf));
        metadata = (struct fanotify_event_metadata *)buf;

        for (; FAN_EVENT_OK(metadata, buflen);
             metadata = FAN_EVENT_NEXT(metadata, buflen)) {

            const char *event_type = "UNKNOWN";
            if (metadata->mask & FAN_CREATE)
                event_type = "CREATE";
            else if (metadata->mask & FAN_DELETE)
                event_type = "DELETE";
            else if (metadata->mask & FAN_MODIFY)
                event_type = "MODIFY";
            else if (metadata->mask & FAN_MOVED_FROM)
                event_type = "MOVED_FROM";
            else if (metadata->mask & FAN_MOVED_TO)
                event_type = "MOVED_TO";
            else if (metadata->mask & FAN_ATTRIB)
                event_type = "ATTRIB";

            fid = (struct fanotify_event_info_fid *)(metadata + 1);

            if (fid->hdr.info_type == FAN_EVENT_INFO_TYPE_DFID_NAME) {
                struct file_handle *dir_fh = (struct file_handle *)fid->handle;
                char *child_name = (char *)dir_fh->f_handle + dir_fh->handle_bytes;

                int dirfd = open_by_handle_at(mount_fd, dir_fh, O_PATH | O_RDONLY);
                if (dirfd == -1) {
                    // Cannot determine path, skip this event
                    if (errno == ESTALE)
                        continue;
                    else {
                        perror("open_by_handle_at(dir)");
                        exit(EXIT_FAILURE);
                    }
                }

                char fdpath[64];
                char dirpath[PATH_MAX + 1];
                snprintf(fdpath, sizeof(fdpath), "/proc/self/fd/%d", dirfd);

                ssize_t linklen = readlink(fdpath, dirpath, sizeof(dirpath) - 1);
                if (linklen == -1) {
                    perror("readlink(dir)");
                    close(dirfd);
                    continue;
                }
                dirpath[linklen] = '\0';

                // Remove " (deleted)" suffix if present
                const char *deleted_suffix = " (deleted)";
                size_t suflen = strlen(deleted_suffix);
                if ((size_t)linklen >= suflen &&
                    strcmp(dirpath + linklen - suflen, deleted_suffix) == 0) {
                    dirpath[linklen - suflen] = '\0';
                }

                // Construct full path: dirpath + '/' + child_name
                char fullpath[PATH_MAX + 1];
                size_t dirlen = strlen(dirpath);
                size_t namelen = strlen(child_name);

                if (dirlen > PATH_MAX) dirlen = PATH_MAX;

                size_t need_sep = (dirlen > 0 && dirpath[dirlen - 1] == '/') ? 0 : 1;
                size_t avail = (dirlen >= PATH_MAX) ? 0 : (PATH_MAX - dirlen - need_sep);
                size_t copylen = (namelen > avail) ? avail : namelen;

                size_t pos = 0;
                if (dirlen > 0) {
                    memcpy(fullpath, dirpath, dirlen);
                    pos = dirlen;
                }
                if (need_sep && avail > 0) {
                    fullpath[pos++] = '/';
                }
                if (copylen > 0) {
                    memcpy(fullpath + pos, child_name, copylen);
                    pos += copylen;
                }
                fullpath[pos] = '\0';

                // --- Path filtering ---
                // Only print events whose fullpath is under the watched directory
                if (!is_root) {
                    if (strncmp(fullpath, watch_path, watch_len) != 0 ||
                        (fullpath[watch_len] != '\0' && fullpath[watch_len] != '/')) {
                        close(dirfd);
                        continue;  // skip this event
                    }
                }

                // Event is inside the watched tree -> print it
                printf("%s\t%s\n", event_type, fullpath);
                fflush(stdout);
                close(dirfd);
            }
        }
    }
}