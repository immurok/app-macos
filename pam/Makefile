# Makefile for pam_immurok

CC = clang
CFLAGS = -fPIC -Wall -Wextra -O2
LDFLAGS = -shared -lpam

# Build for both arm64 and x86_64
ARCH_FLAGS = -arch arm64 -arch x86_64

TARGET = pam_immurok.so
SRC = pam_immurok.c
SIGN_IDENTITY ?= -

.PHONY: all clean install uninstall

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(ARCH_FLAGS) $(LDFLAGS) -o $@ $<
	codesign --force --sign "$(SIGN_IDENTITY)" $@

clean:
	rm -f $(TARGET)

install: $(TARGET)
	@sudo mkdir -p /usr/local/lib/pam
	sudo cp $(TARGET) /usr/local/lib/pam/
	@echo ""
	@echo "Installed to /usr/local/lib/pam/$(TARGET)"
	@echo ""
	@echo "To enable, add this line to /etc/pam.d/sudo (at the top):"
	@echo "  auth sufficient /usr/local/lib/pam/pam_immurok.so"
	@echo ""

uninstall:
	sudo rm -f /usr/local/lib/pam/$(TARGET)
	@echo "Removed /usr/local/lib/pam/$(TARGET)"
