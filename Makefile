# Compiler and flags
CC = gcc
CFLAGS = -Wall -Wextra -O2
LDFLAGS =

# Target executable
TARGET = fawatch

# Source files
SRCS = main.c
OBJS = $(SRCS:.c=.o)

# Installation paths
PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
SCRIPTS = fasync.sh

# Systemd paths
SYSTEMDDIR = /etc/systemd/system
SERVICE_FILE = fasync@.service

# Configuration paths
CONFIGDIR = /etc/default
CONFIG_EXAMPLE = fasync-example

# Default target
all: $(TARGET)

# Link object file into executable
$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

# Compile source file into object file
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Install: copy binaries, scripts, systemd template and config example from repo
install: all
	# Install executable and script
	install -m 755 -d $(BINDIR)
	install -m 755 $(TARGET) $(BINDIR)
	install -m 755 $(SCRIPTS) $(BINDIR)
	
	# Install systemd service template from repository
	install -m 755 -d $(SYSTEMDDIR)
	install -m 644 $(SERVICE_FILE) $(SYSTEMDDIR)/$(SERVICE_FILE)
	
	# Install configuration example if not already present
	install -m 755 -d $(CONFIGDIR)
	@if [ ! -f $(CONFIGDIR)/$(CONFIG_EXAMPLE) ]; then \
		install -m 644 $(CONFIG_EXAMPLE) $(CONFIGDIR)/$(CONFIG_EXAMPLE); \
		echo "Installed configuration example to $(CONFIGDIR)/$(CONFIG_EXAMPLE)"; \
	fi

	# Reload systemd configuration if systemctl is available
	if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; fi

# Uninstall: remove all installed files and reload systemd
uninstall:
	cd $(BINDIR) && rm -f $(TARGET) $(SCRIPTS)
	rm -f $(SYSTEMDDIR)/$(SERVICE_FILE)
	rm -f $(CONFIGDIR)/$(CONFIG_EXAMPLE)
	if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; fi

# Clean build artifacts
clean:
	rm -f $(OBJS) $(TARGET)

# Phony targets (not files)
.PHONY: all clean install uninstall

