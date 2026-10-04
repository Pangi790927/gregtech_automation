# 3d-draw's program (main.cpp), built as the simulator is (simulator/windows.makefile, whose flags
# and sources this repeats), with the simulator's composers taken from ../simulator as they are
# (3d-draw/redesign/06-pc.md: included, never copied). glfw3.lib and glfw3.dll are the
# simulator's too; the dll is copied beside main.exe, which needs it to start.
ISYM      := /I
CSYM      := /c
CXX       := cl

CXX_FLAGS := /EHs /await:strict /std:c++20 /Zi /MD /Zc:preprocessor /O2
# Lua reads the chunk files and the settings itself, so it needs the io library.
CXX_FLAGS += /DVIRT_COMPOSER_ENABLE_LUA_IO=1

ifeq (${ASAN},1)
CXX_FLAGS += /fsanitize=address
endif

SIM       := ../simulator/
LIBS      := /link /LIBPATH:${SIM} gdi32.lib glfw3.lib opengl32.lib

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

# ${SIM} first: utils/vulkan has an imgui_composer.h of its own, which the simulator never meets
# because its main.cpp sits beside its own (a quoted include looks in the includer's folder
# first). ${UTILS}/vulkan is on the list for stb_image.h alone, as in the simulator's makefile.
INCLCUDES := /I. /I${SIM}
INCLCUDES += /I${UTILS} /I${UTILS}/ap /I${UTILS}/co /I${UTILS}/generic /I${UTILS}/vulkan
INCLCUDES += /I${IMGUI} /I${IMGUI}/backends/ /I${IMPLOT}

DEPS      := $(wildcard ./*.h) $(wildcard ${SIM}/*.h)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
SRCS      += ${UTILS}/virt_composer.cpp
OBJS      := $(SRCS:.cpp=.obj)

all: ${OBJS} $(DEPS) glfw3.dll
	${CXX} ${CXX_FLAGS} ${INCLCUDES} main.cpp $(notdir ${OBJS}) ${LIBS}

glfw3.dll: ${SIM}/glfw3.dll
	cp ${SIM}/glfw3.dll .

${OBJS}:$(notdir %.obj):%.cpp
	${CXX} /c ${CXX_FLAGS} ${INCLCUDES} $< /link /OUT $(notdir $@)

clean:
	rm -f *.obj
	rm -f *.exe
	rm -f *.ilk
	rm -f *.pdb
