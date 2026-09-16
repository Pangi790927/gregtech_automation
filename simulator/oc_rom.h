#ifndef OC_ROM_H
#define OC_ROM_H

/*! oc_rom.h - the Lua that OpenComputers itself ships, read out of the mod jar.
 *
 * Core: the guest side of this simulator is not written here. The sandbox, the scheduler, the BIOS
 * and the whole of OpenOS are Lua files inside `OpenComputers-*.jar`, and the mod runs exactly
 * those. So does this: the jar is already open for textures, and the same zip reader gets the code.
 *
 * What that buys is not a shortcut. It is that `component`, `event`, `thread`, `filesystem`, `term`
 * and the rest behave the way the real mod's do because they ARE the real mod's, which is the only
 * way a program written against OpenComputers can be trusted to run here unchanged.
 *
 * Nothing is cached: a machine reads its ROM once at boot, and the jar is a few megabytes already
 * held by the asset loader.
 *
 * @date 2026-09-16 */

#include "mc_assets.h"

#include <string>
#include <vector>

namespace oc_rom {

namespace mca = mc_assets;

/*! Where the mod keeps the two files a machine needs before it has an operating system.
 * @date 2026-09-16 */
constexpr const char *MACHINE_PATH = "assets/opencomputers/lua/machine.lua";
constexpr const char *BIOS_PATH    = "assets/opencomputers/lua/bios.lua";

/*! The sandbox and scheduler the mod runs every computer inside, as source.
 *
 * Returns an empty string when the jar is not open or the entry is missing, which a caller reports
 * as a machine that cannot start rather than as a crash - a user without the modpack should be told
 * why, not dropped.
 * @date 2026-09-16 */
inline std::string machine_source(const mca::mc_source_t &src) {
    if (!src.is_open())
        return {};
    std::vector<uint8_t> bytes = mca::zip_extract(src.jar, MACHINE_PATH);
    return std::string(bytes.begin(), bytes.end());
}

/*! The default EEPROM's contents - the BIOS that finds a filesystem and boots it.
 * @date 2026-09-16 */
inline std::string bios_source(const mca::mc_source_t &src) {
    if (!src.is_open())
        return {};
    std::vector<uint8_t> bytes = mca::zip_extract(src.jar, BIOS_PATH);
    return std::string(bytes.begin(), bytes.end());
}

} /* namespace oc_rom */

#endif /* OC_ROM_H */
