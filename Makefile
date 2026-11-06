APP_NAME := PinShot
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: all build fast run stop test typecheck render-test install clean help

all: build

build:
	./scripts/build.sh

fast:
	./scripts/build.sh --fast

run: build
	@open "$(APP)" && echo "PinShot 已启动（看菜单栏的 📌）"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@echo "已停止 PinShot"

test:
	./scripts/test.sh

typecheck:
	./scripts/typecheck.sh

render-test: build
	"$(APP)/Contents/MacOS/PinShot" --render-test "$(BUILD_DIR)/render"

install: build
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "$(HOME)/Applications/"
	@echo "已安装到 ~/Applications/$(APP_NAME).app"

clean:
	rm -rf "$(BUILD_DIR)"

help:
	@echo "make build        编译并打包 build/PinShot.app"
	@echo "make fast         快速编译（-Onone）"
	@echo "make run          编译并启动"
	@echo "make stop         停止运行"
	@echo "make test         运行单元测试"
	@echo "make typecheck    只做类型检查"
	@echo "make render-test  离屏渲染自检，产物在 build/render/"
	@echo "make install      安装到 ~/Applications 并启动"
