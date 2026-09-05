# Makefile for pam_immurok

CC = clang
CFLAGS = -fPIC -Wall -Wextra -O2
LDFLAGS = -shared -lpam

# Build for both arm64 and x86_64
ARCH_FLAGS = -arch arm64 -arch x86_64

TARGET = pam_immurok.so
SRC = pam_immurok.c hmac_sha256.c pam_auth_verify.c
SIGN_IDENTITY ?= -

.PHONY: all clean install uninstall test vectors

all: $(TARGET)

$(TARGET): $(SRC) hmac_sha256.h pam_auth_verify.h
	$(CC) $(CFLAGS) $(ARCH_FLAGS) $(LDFLAGS) -o $@ $(SRC)
	codesign --force --sign "$(SIGN_IDENTITY)" $@

vectors:
	python3 gen_vectors.py

test: test_pam_mac
	./test_pam_mac

test_pam_mac: test_pam_mac.c hmac_sha256.c pam_auth_verify.c hmac_sha256.h pam_auth_verify.h test_vectors.h
	$(CC) -Wall -Wextra -O2 -o $@ test_pam_mac.c hmac_sha256.c pam_auth_verify.c

clean:
	rm -f $(TARGET) test_pam_mac

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
