# The console runs on the user's Windows PC; only the relay also builds for Linux, to run on the
# Minecraft server beside the computers (console/docs/install.md). On Windows `make` builds
# everything there; `make -f linux.makefile`, in WSL, builds the relay for the server.
ifeq (${OS},Windows_NT)
include windows.makefile
else
include linux.makefile
endif
