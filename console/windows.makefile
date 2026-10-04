CXX       := cl

# The same flags as simulator/windows.makefile: /O2, since MSVC builds at /Od without an /O flag.
CXX_FLAGS := /nologo /EHs /await:strict /std:c++20 /Zi /MD /Zc:preprocessor /O2 /utf-8

UTILS     := ../../utils/
INCLUDES  := /I${UTILS} /I.
LIBS      := /link ws2_32.lib mswsock.lib user32.lib

# The agents: connectors, each in its own folder with its payload, built there as <name>.exe,
# because it reads its payload from beside itself.
AGENTS    := term claude-oc ocscp

# Header-only apart from one .cpp per program; colib is a single header.
DEPS      := $(wildcard ./*.h)

# conhelp.exe is Claude's hands on term.exe (term/DESIGN.md, "Using it from Claude").
all: relay.exe tests.exe conhelp.exe $(foreach a,${AGENTS},$(a)/$(a).exe)

# The shared programs. tests.exe reaches into the agents' headers too.
%.exe: %.cpp ${DEPS} $(foreach a,${AGENTS},$(wildcard $(a)/*.h))
	${CXX} ${CXX_FLAGS} ${INCLUDES} $(addprefix /I,${AGENTS}) $< /Fe:$@ ${LIBS}

define agent_rule
$(1)/$(1).exe: $(1)/$(1).cpp $${DEPS} $$(wildcard $(1)/*.h)
	$${CXX} $${CXX_FLAGS} $${INCLUDES} $$< /Fe:$$@ /Fo:$(1)/ /Fd:$(1)/ $${LIBS}
endef
$(foreach a,${AGENTS},$(eval $(call agent_rule,$(a))))

test: tests.exe
	./tests.exe

clean:
	rm -f *.obj *.exe *.ilk *.pdb $(foreach a,${AGENTS},$(a)/*.obj $(a)/*.exe $(a)/*.ilk $(a)/*.pdb)
