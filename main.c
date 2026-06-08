#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/fanotify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

int main(int argc, char **argv)
{
	int fan;
	int mount_fd;
	char buf[4096];
	struct file_handle *file_handle;

	ssize_t buflen;
	struct fanotify_event_metadata *metadata;
	struct fanotify_event_info_fid *fid;

	if (argc != 2)
	{
		fprintf(stderr, "Usage: %s /dir\n", argv[0]);
		exit(EXIT_FAILURE);
	}

	mount_fd = open(argv[1], O_DIRECTORY | O_RDONLY);
	if (mount_fd == -1)
	{
		perror(argv[1]);
		exit(EXIT_FAILURE);
	}

	fan = fanotify_init(FAN_CLASS_NOTIF | FAN_REPORT_FID | FAN_REPORT_DFID_NAME, O_RDONLY | O_LARGEFILE);
	if (fan == -1)
	{
		perror("fanotify_init");
		exit(EXIT_FAILURE);
	}

	int ret = fanotify_mark(fan,
													FAN_MARK_ADD | FAN_MARK_FILESYSTEM,
													FAN_CREATE | FAN_DELETE | FAN_MODIFY,
													AT_FDCWD,
													argv[1]);
	if (ret == -1)
	{
		perror("fanotify_mark");
		exit(EXIT_FAILURE);
	}

	while (1)
	{
		buflen = read(fan, buf, sizeof(buf));
		metadata = (struct fanotify_event_metadata *)&buf;

		for (; FAN_EVENT_OK(metadata, buflen); metadata = FAN_EVENT_NEXT(metadata, buflen))
		{
			fid = (struct fanotify_event_info_fid *)(metadata + 1);
			file_handle = (struct file_handle *)fid->handle;

			if (fid->hdr.info_type == FAN_EVENT_INFO_TYPE_DFID_NAME)
			{
				/* file_handle is for the directory; child name follows the handle bytes */
				struct file_handle *dir_fh = file_handle;
				char *child_name = (char *)dir_fh->f_handle + dir_fh->handle_bytes;

				/* open the directory by handle to get a fd we can readlink from */
				int dirfd = open_by_handle_at(mount_fd, dir_fh, O_PATH | O_RDONLY);
				if (dirfd == -1)
				{
					if (errno == ESTALE)
					{
						printf("%s\n", child_name); /* dir gone; at least print name */
						continue;
					}
					else
					{
						perror("open_by_handle_at(dir)");
						exit(EXIT_FAILURE);
					}
				}

				char fdpath[64];
				char dirpath[PATH_MAX + 1];
				snprintf(fdpath, sizeof(fdpath), "/proc/self/fd/%d", dirfd);

				ssize_t linklen = readlink(fdpath, dirpath, sizeof(dirpath) - 1);
				if (linklen == -1)
				{
					perror("readlink(dir)");
					close(dirfd);
					continue;
				}
				dirpath[linklen] = '\0';

				/* remove " (deleted)" suffix if present */
				const char *deleted_suffix = " (deleted)";
				size_t suflen = strlen(deleted_suffix);
				if ((size_t)linklen >= suflen &&
						strcmp(dirpath + linklen - suflen, deleted_suffix) == 0)
				{
					dirpath[linklen - suflen] = '\0';
				}

				/* dirpath and child_name are set and dirpath is NUL-terminated */

				char fullpath[PATH_MAX + 1];
				size_t dirlen = strlen(dirpath);
				size_t namelen = strlen(child_name);

				/* Ensure dirlen <= PATH_MAX */
				if (dirlen > PATH_MAX)
					dirlen = PATH_MAX;

				/* Compute available space for name (+1 for '/' if needed, +1 for NUL) */
				size_t need_sep = (dirlen > 0 && dirpath[dirlen - 1] == '/') ? 0 : 1;
				size_t avail = (dirlen >= PATH_MAX) ? 0 : (PATH_MAX - dirlen - need_sep);

				/* Copy directory part */
				if (dirlen > 0)
				{
					memcpy(fullpath, dirpath, dirlen);
				}
				size_t copylen = (namelen > avail) ? avail : namelen;

				/* Add separator if required and there is space */
				size_t pos = dirlen;
				if (need_sep && avail > 0)
				{
					fullpath[pos++] = '/';
					avail--; /* one less for name */
				}

				/* Copy (possibly truncated) child name */
				if (copylen > 0)
				{
					memcpy(fullpath + pos, child_name, copylen);
					pos += copylen;
				}

				/* NUL terminate */
				fullpath[pos] = '\0';

				printf("%s\n", fullpath);
				fflush(stdout);
				close(dirfd);
			}

			close(metadata->fd);
			metadata = FAN_EVENT_NEXT(metadata, buflen);
		}
	}
}
