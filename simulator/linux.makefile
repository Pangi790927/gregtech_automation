CXX       := g++
CXX_FLAGS := -std=c++2a -O3 -g -export-dynamic -Wno-format-security
# Lua opens the settings file and writes the world save itself, so it needs the io library.
CXX_FLAGS += -DVIRT_COMPOSER_ENABLE_LUA_IO=1
LIBS      := -lpthread -ldl -lglfw -lGL -lbacktrace

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
INCLCUDES := -I${UTILS} -I${UTILS}/ap -I${UTILS}/co -I${UTILS}/generic -I${UTILS}/vulkan -I.
INCLCUDES += -I${IMGUI} -I${IMGUI}/backends/ -I${IMPLOT}

DEPS      := $(wildcard ./*.h)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
SRCS      += ${UTILS}/virt_composer.cpp
OBJS      := $(SRCS:.cpp=.o)

all: ${OBJS} $(DEPS)
	${CXX} ${CXX_FLAGS} ${INCLCUDES} main.cpp ${OBJS} ${LIBS}

${OBJS}:%.o:%.cpp
	${CXX} -c ${CXX_FLAGS} ${INCLCUDES} $< -o $@

clean:
	rm -f *.o
	rm -f ${OBJS}
	rm -f *.obj
	rm -f *.exe
	rm -f *.ilk
	rm -f *.pdb
