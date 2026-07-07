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

# Default target
all: $(TARGET)

# Link object file into executable
$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

# Compile source file into object file
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Install: copy fawatch and fasync.sh to BINDIR
install: all
	install -m 755 -d $(BINDIR)
	install -m 755 $(TARGET) $(BINDIR)
	install -m 755 $(SCRIPTS) $(BINDIR)

# Uninstall: remove installed files
uninstall:
	cd $(BINDIR) && rm -f $(TARGET) $(SCRIPTS)

# Clean build artifacts
clean:
	rm -f $(OBJS) $(TARGET)

# Phony targets (not files)
.PHONY: all clean install uninstall
