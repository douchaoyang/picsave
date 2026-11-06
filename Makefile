ARCH := arm64
MIN_OS := 14.0
OUT_DIR := build
OUT := $(OUT_DIR)/picsave.dylib

SYSROOT := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := $(shell xcrun --sdk iphoneos -f clang)

SRCS := \
	src/PSMain.m \
	src/PSImageProbe.m \
	src/PSDownloadCard.m \
	src/PSProgressHUD.m \
	src/PSDownloader.m

# 关掉 selector stubs，避免注入到不同版本的 App 后 dyld 解析失败。
CFLAGS := \
	-arch $(ARCH) \
	-isysroot $(SYSROOT) \
	-miphoneos-version-min=$(MIN_OS) \
	-fobjc-arc \
	-fno-objc-msgsend-selector-stubs \
	-O2 \
	-Wall \
	-Wextra \
	-Wno-unused-parameter

LDFLAGS := \
	-dynamiclib \
	-Wl,-install_name,@rpath/picsave.dylib \
	-framework Foundation \
	-framework UIKit \
	-framework CoreGraphics \
	-framework QuartzCore \
	-framework WebKit

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS)
	mkdir -p $(OUT_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $(OUT)

clean:
	rm -rf $(OUT_DIR)
