#ifndef CLASS_READER_H
#define CLASS_READER_H

/*! class_reader.h - just enough of a Java class file to read constants out of compiled code.
 *
 * Core: SOME OF WHAT THE SIMULATOR NEEDS IS ONLY IN A MOD'S BYTECODE. GregTech's material list is
 * the case that forced this: fourteen thousand of its item names are templates like
 * `%material Dust`, keyed by a number that decomposes into a shape and a material, and the material
 * list - which id is which material, what colour it is, which texture set draws it - is built in
 * the static initialiser of `gregtech/api/enums/Materials` and written to no file. The lang file
 * has the display names but keys them by material name, so without the bytecode nothing joins the
 * two and a search for a naquadah dust finds nothing.
 *
 * A LEAF, and deliberately ignorant: it knows class files, not GregTech. What the patterns mean is
 * mc_assets.h's business.
 *
 * It is NOT a verifier, a loader or a disassembler. It parses the constant pool, finds a method's
 * code, and hands the bytes over - the callers scan those bytes for the shapes they know. That is
 * enough for reading constants out of an initialiser and nothing like enough to run anything,
 * which is the point: there is no appetite here for a JVM.
 *
 * @date 2026-09-17 */

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace class_reader {

/*! One constant pool entry, in the shapes worth keeping. @date 2026-09-17 */
struct constant_t {
    uint8_t tag = 0;
    std::string text;       /*!< tag 1, a utf8 */
    int32_t ival = 0;       /*!< tag 3, an integer */
    uint32_t a = 0, b = 0;  /*!< class/string: the name index. refs: class and name-and-type */
};

/*! A parsed class file: its pool, and where to find a method's code. @date 2026-09-17 */
struct class_file_t {
    std::vector<constant_t> pool;
    bool ok = false;

    const uint8_t *code = nullptr;      /*!< the code of the method last asked for */
    uint32_t code_len = 0;

    const std::string &utf8(uint32_t i) const {
        static const std::string none;
        return (i && i < pool.size() && pool[i].tag == 1) ? pool[i].text : none;
    }

    /*! The name of a class constant, such as "gregtech/api/enums/Materials". @date 2026-09-17 */
    const std::string &class_name(uint32_t i) const {
        static const std::string none;
        if (!i || i >= pool.size() || pool[i].tag != 7)
            return none;
        return utf8(pool[i].a);
    }

    /*! A field or method reference, as its class, its name and its descriptor. @date 2026-09-17 */
    bool ref(uint32_t i, std::string &cls, std::string &name, std::string &desc) const {
        if (!i || i >= pool.size())
            return false;
        uint8_t t = pool[i].tag;
        if (t != 9 && t != 10 && t != 11)
            return false;

        uint32_t nat = pool[i].b;
        if (nat >= pool.size() || pool[nat].tag != 12)
            return false;

        cls = class_name(pool[i].a);
        name = utf8(pool[nat].a);
        desc = utf8(pool[nat].b);
        return true;
    }

    /*! The integer a constant holds, or `def` when it is not one. @date 2026-09-17 */
    int32_t integer(uint32_t i, int32_t def) const {
        return (i && i < pool.size() && pool[i].tag == 3) ? pool[i].ival : def;
    }
};

/*! Reads a class file's constant pool and finds one method's code.
 *
 * `method` is matched by name alone - "<init>", "<clinit>" - and the FIRST match wins, which is
 * what a caller reading a static initialiser wants and is a real limit for an overloaded method.
 *
 * Returns a class_file_t whose `ok` says whether the pool parsed; `code` is null when the method
 * was not there. Anything unexpected in the file stops the parse rather than guessing, because a
 * pool walked wrongly gives confident nonsense rather than an error.
 *
 * @date 2026-09-17 */
inline class_file_t read_class(const std::vector<uint8_t> &data, const char *method) {
    class_file_t cf;
    if (data.size() < 24)
        return cf;

    const uint8_t *d = data.data();
    size_t len = data.size();
    auto u2 = [&](size_t at) -> uint32_t {
        return (at + 1 < len) ? (uint32_t)((d[at] << 8) | d[at + 1]) : 0;
    };
    auto u4 = [&](size_t at) -> uint32_t {
        if (at + 3 >= len)
            return 0;
        return (uint32_t)((d[at] << 24) | (d[at + 1] << 16) | (d[at + 2] << 8) | d[at + 3]);
    };

    uint32_t count = u2(8);
    cf.pool.assign(count + 1, constant_t());

    size_t p = 10;
    for (uint32_t n = 1; n < count && p < len; n++) {
        uint8_t tag = d[p];
        cf.pool[n].tag = tag;
        switch (tag) {
            case 1: {
                uint32_t l = u2(p + 1);
                if (p + 3 + l > len)
                    return cf;
                cf.pool[n].text.assign((const char *)d + p + 3, l);
                p += 3 + l;
                break;
            }
            case 3: cf.pool[n].ival = (int32_t)u4(p + 1); p += 5; break;
            case 4: p += 5; break;
            /* A long or a double takes two pool slots. Getting this wrong shifts every index
            after it, which is exactly the confident nonsense mentioned above. */
            case 5: case 6: p += 9; n++; break;
            case 7: case 8: cf.pool[n].a = u2(p + 1); p += 3; break;
            case 9: case 10: case 11: case 12:
                cf.pool[n].a = u2(p + 1);
                cf.pool[n].b = u2(p + 3);
                p += 5;
                break;
            case 15: p += 4; break;
            case 16: case 19: case 20: p += 3; break;
            case 17: case 18: p += 5; break;
            default: return cf;
        }
    }
    cf.ok = true;

    p += 6;                             /* access flags, this class, super class */
    p += 2 + 2u * u2(p);                /* the interfaces */

    /* The fields, skipped whole - only their attribute lengths matter here. */
    uint32_t fcount = u2(p);
    p += 2;
    for (uint32_t i = 0; i < fcount && p < len; i++) {
        p += 6;
        uint32_t ac = u2(p);
        p += 2;
        for (uint32_t k = 0; k < ac && p < len; k++)
            p += 6 + u4(p + 2);
    }

    uint32_t mcount = u2(p);
    p += 2;
    for (uint32_t i = 0; i < mcount && p < len; i++) {
        p += 2;
        const std::string &mname = cf.utf8(u2(p));
        p += 4;
        uint32_t ac = u2(p);
        p += 2;
        for (uint32_t k = 0; k < ac && p < len; k++) {
            const std::string &aname = cf.utf8(u2(p));
            uint32_t alen = u4(p + 2);
            if (!cf.code && mname == method && aname == "Code") {
                /* max_stack, max_locals, then the code length and the code itself. */
                cf.code_len = u4(p + 6 + 4);
                if (p + 6 + 8 + cf.code_len <= len)
                    cf.code = d + p + 6 + 8;
                else
                    cf.code_len = 0;
            }
            p += 6 + alen;
        }
    }
    return cf;
}

/*! The integer a push instruction at `at` carries, and how long that instruction is.
 *
 * Handles the forms a constant argument is actually written with: the iconst family, bipush,
 * sipush, and ldc of an integer constant. Answers false for anything else, which is how a caller
 * tells "the next argument is not a number" from "it is nought".
 * @date 2026-09-17 */
inline bool int_push(const class_file_t &cf, const uint8_t *code, uint32_t len, uint32_t at,
        int32_t &value, uint32_t &size) {
    if (at >= len)
        return false;

    uint8_t op = code[at];
    if (op >= 0x02 && op <= 0x08) {              /* iconst_m1 .. iconst_5 */
        value = (int32_t)op - 0x03;
        size = 1;
        return true;
    }
    if (op == 0x10 && at + 1 < len) {            /* bipush */
        value = (int8_t)code[at + 1];
        size = 2;
        return true;
    }
    if (op == 0x11 && at + 2 < len) {            /* sipush */
        value = (int16_t)((code[at + 1] << 8) | code[at + 2]);
        size = 3;
        return true;
    }
    if (op == 0x12 && at + 1 < len) {            /* ldc */
        value = cf.integer(code[at + 1], INT32_MIN);
        size = 2;
        return value != INT32_MIN;
    }
    if (op == 0x13 && at + 2 < len) {            /* ldc_w */
        value = cf.integer((uint32_t)((code[at + 1] << 8) | code[at + 2]), INT32_MIN);
        size = 3;
        return value != INT32_MIN;
    }
    return false;
}

} /* namespace class_reader */

#endif /* CLASS_READER_H */
