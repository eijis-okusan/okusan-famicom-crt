APP_NAME   := Okusan Famicom CRT
EXEC_NAME  := OkusanFamicomCRT
BUILD_DIR  := build
BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
BIN        := $(BUNDLE)/Contents/MacOS/$(EXEC_NAME)

CORE_DIR   := third_party/fceumm
CORE_DYLIB := $(CORE_DIR)/fceumm_libretro.dylib

ARCH       ?= $(shell uname -m)
CXX        := clang++
CXXFLAGS   := -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -Isrc -DGL_SILENCE_DEPRECATION -arch $(ARCH)
OBJCFLAGS  := -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework OpenGL -framework AudioToolbox -framework GameController -framework UniformTypeIdentifiers

CPP_SRCS   := src/core/FamicomCore.cpp
MM_SRCS    := src/app/main.mm \
              src/app/AppDelegate.mm \
              src/app/AppLocalization.mm \
              src/audio/MacAudioEngine.mm \
              src/video/CrtScreenView.mm \
              src/hud/CartConnectorHud.mm \
              src/input/InputBindings.mm \
              src/input/ControllerSettingsWindow.mm

CPP_OBJS   := $(patsubst src/%.cpp,$(BUILD_DIR)/obj/%.o,$(CPP_SRCS))
MM_OBJS    := $(patsubst src/%.mm,$(BUILD_DIR)/obj/%.o,$(MM_SRCS))
OBJS       := $(CPP_OBJS) $(MM_OBJS)

.PHONY: all app core run clean distclean

all: app

core: $(CORE_DYLIB)

$(CORE_DYLIB):
	$(MAKE) -C $(CORE_DIR) -f Makefile.libretro -j4

$(BUILD_DIR)/obj/%.o: src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/obj/%.o: src/%.mm
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(OBJCFLAGS) -c $< -o $@

app: $(CORE_DYLIB) $(OBJS) resources/Info.plist resources/AppIcon.icns resources/shaders/*.glsl LICENSE
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Frameworks" "$(BUNDLE)/Contents/Resources/shaders"
	$(CXX) -arch $(ARCH) $(OBJCFLAGS) $(OBJS) $(FRAMEWORKS) -o "$(BIN)"
	@cp resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@cp LICENSE "$(BUNDLE)/Contents/Resources/LICENSE.txt"
	@cp resources/shaders/*.glsl "$(BUNDLE)/Contents/Resources/shaders/"
	@cp "$(CORE_DYLIB)" "$(BUNDLE)/Contents/Frameworks/fceumm_libretro.dylib"
	@install_name_tool -id "@executable_path/../Frameworks/fceumm_libretro.dylib" "$(BUNDLE)/Contents/Frameworks/fceumm_libretro.dylib"
	@codesign --force --sign - "$(BUNDLE)/Contents/Frameworks/fceumm_libretro.dylib"
	@codesign --force --deep --sign - "$(BUNDLE)"

run: app
	open "$(BUNDLE)"

clean:
	@rm -rf $(BUILD_DIR)

distclean: clean
	$(MAKE) -C $(CORE_DIR) -f Makefile.libretro clean
