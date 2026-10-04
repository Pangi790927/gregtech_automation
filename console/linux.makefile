# The relay alone, for the Minecraft server (docs/install.md, "The relay on the server"). Built
# here in WSL and copied there: the server is Ubuntu 18.04, whose glibc is older than WSL's and
# whose g++ has no C++20 coroutines, so the program is linked whole, with nothing to find on the
# server.
CXX       := g++
CXX_FLAGS := -std=c++20 -O2 -static -Wall -Wno-unused-function

UTILS     := ../../utils/
INCLUDES  := -I${UTILS} -I.

all: relay

relay: relay.cpp relay.h net.h protocol.h screen.h
	${CXX} ${CXX_FLAGS} ${INCLUDES} $< -o $@

clean:
	rm -f relay
