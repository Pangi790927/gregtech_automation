ISYM      := /I
CSYM      := /c
CXX       := cl

# /O2, matching math_writer's. Without an explicit /O flag MSVC compiles at /Od, so ImGui and
# virt_composer would both build unoptimised. There is no /O3 in MSVC - that is a GCC flag.
CXX_FLAGS := /EHs /await:strict /std:c++20 /Zi /MD /Zc:preprocessor /O2
# Lua opens the settings file and writes the world save itself, so it needs the io library.
CXX_FLAGS += /DVIRT_COMPOSER_ENABLE_LUA_IO=1

# ASAN=1 builds with the address sanitizer: `make clean && make ASAN=1`. Off by default, and
# `make clean` first is not optional - instrumented and uninstrumented objects must not be linked
# together, and a partial rebuild will happily do exactly that. Never measure with this on.
ifeq (${ASAN},1)
CXX_FLAGS += /fsanitize=address
endif

LIBS      := /link gdi32.lib glfw3.lib opengl32.lib

IMGUI     := ../../imgui/
IMPLOT    := ../../implot/
UTILS     := ../../utils/

IMGUI_SRC := ${IMGUI}/imgui.cpp
IMGUI_SRC += ${IMGUI}/imgui_draw.cpp
IMGUI_SRC += ${IMGUI}/imgui_tables.cpp
IMGUI_SRC += ${IMGUI}/imgui_widgets.cpp
IMGUI_SRC += ${IMGUI}/imgui_demo.cpp

IMPLOT_SRC := ${IMPLOT}/implot.cpp
IMPLOT_SRC += ${IMPLOT}/implot_demo.cpp
IMPLOT_SRC += ${IMPLOT}/implot_items.cpp

BACKEND_SRC := ${IMGUI}/backends/imgui_impl_glfw.cpp
BACKEND_SRC += ${IMGUI}/backends/imgui_impl_opengl3.cpp

# ${UTILS}/vulkan is on the list for stb_image.h alone - it is the only image decoder in utils, and
# it happens to live beside the vulkan helpers. Nothing vulkan is compiled or linked here.
INCLCUDES := /I${UTILS} /I${UTILS}/ap /I${UTILS}/co /I${UTILS}/generic /I${UTILS}/vulkan /I.
INCLCUDES += /I${IMGUI} /I${IMGUI}/backends/ /I${IMPLOT}

# This is a header-only project apart from the two sources below.
DEPS      := $(wildcard ./*.h)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
SRCS      += ${UTILS}/virt_composer.cpp
OBJS      := $(SRCS:.cpp=.obj)

all: ${OBJS} $(DEPS)
	${CXX} ${CXX_FLAGS} ${INCLCUDES} main.cpp $(notdir ${OBJS}) ${LIBS}

${OBJS}:$(notdir %.obj):%.cpp
	${CXX} /c ${CXX_FLAGS} ${INCLCUDES} $< /link /OUT $(notdir $@)

clean:
	rm -f *.obj
	rm -f *.exe
	rm -f *.ilk
	rm -f *.pdb
