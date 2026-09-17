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
    int64_t lval = 0;       /*!< tag 5, a long - how a fluid amount is written */
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

    /*! The long a constant holds, or `def` when it is not one. @date 2026-09-17 */
    int64_t longv(uint32_t i, int64_t def) const {
        return (i && i < pool.size() && pool[i].tag == 5) ? pool[i].lval : def;
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
            case 5:
                cf.pool[n].lval = ((int64_t)u4(p + 1) << 32) | (uint32_t)u4(p + 5);
                p += 9; n++; break;
            case 6: p += 9; n++; break;
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

/*! How many bytes the instruction at `at` occupies, or 0 when it cannot be worked out.
 *
 * Core: A SCAN THAT DOES NOT KNOW THIS IS GUESSING. Reading a code array byte by byte and matching
 * on opcodes will sooner or later match the middle of a wide operand and report a recipe that is
 * not there - and it will look entirely plausible. Stepping instruction by instruction is what
 * makes the difference between reading the code and reading the bytes.
 *
 * The two switch instructions are variable length and padded to a four byte boundary; everything
 * else is a fixed length from the table below. `wide` doubles the operand of the instruction it
 * prefixes.
 *
 * @date 2026-09-17 */
inline uint32_t insn_length(const uint8_t *code, uint32_t len, uint32_t at) {
    if (at >= len)
        return 0;

    uint8_t op = code[at];

    /* tableswitch and lookupswitch: padding to a multiple of four, then their own tables. */
    if (op == 0xAA || op == 0xAB) {
        uint32_t p = at + 1;
        while ((p % 4) != 0)
            p++;
        auto u4 = [&](uint32_t q) -> int32_t {
            if (q + 3 >= len)
                return 0;
            return (int32_t)((code[q] << 24) | (code[q + 1] << 16) | (code[q + 2] << 8)
                    | code[q + 3]);
        };
        if (op == 0xAA) {
            int32_t lo = u4(p + 4), hi = u4(p + 8);
            if (hi < lo)
                return 0;
            return (p + 12 + 4u * (uint32_t)(hi - lo + 1)) - at;
        }
        int32_t n = u4(p + 4);
        if (n < 0)
            return 0;
        return (p + 8 + 8u * (uint32_t)n) - at;
    }

    /* wide: the next instruction's operand is two bytes instead of one, and iinc gains two. */
    if (op == 0xC4) {
        if (at + 1 >= len)
            return 0;
        return (code[at + 1] == 0x84) ? 6u : 4u;
    }

    /* Everything else, by opcode. Indexed by the opcode itself so there is nothing to keep in
    step; a zero means "not an opcode this reads", which stops the walk rather than guessing. */
    /* Checked opcode by opcode against the JVM specification's table. Two rows were wrong the
    first time - getstatic read as one byte and ireturn as unknown - and the symptom was not a
    crash but SILENCE: the walk desynchronised, hit something it could not size, stopped, and every
    recipe after that point simply did not exist. A table like this is worth reading twice. */
    static const uint8_t LEN[256] = {
        /* 0x00 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0x10 */ 2,3,2,3,3,2,2,2,2,2,1,1,1,1,1,1,
        /* 0x20 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0x30 */ 1,1,1,1,1,1,2,2,2,2,2,1,1,1,1,1,
        /* 0x40 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0x50 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0x60 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0x70 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0x80 */ 1,1,1,1,3,1,1,1,1,1,1,1,1,1,1,1,
        /* 0x90 */ 1,1,1,1,1,1,1,1,1,1,3,3,3,3,3,3,
        /* 0xA0 */ 3,3,3,3,3,3,3,3,3,2,0,0,1,1,1,1,
        /* 0xB0 */ 1,1,3,3,3,3,3,3,3,5,5,3,2,3,1,1,
        /* 0xC0 */ 3,3,1,1,0,4,3,3,5,5,1,1,1,1,1,1,
        /* 0xD0 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0xE0 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        /* 0xF0 */ 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    };
    uint32_t n = LEN[op];
    return (n && at + n <= len) ? n : 0;
}

/*! One method's name and its code. @date 2026-09-17 */
struct method_code_t {
    std::string name;
    const uint8_t *code = nullptr;
    uint32_t len = 0;
};

/*! Reads a class and hands back EVERY method's code.
 *
 * read_class() takes the first method of a given name, which is what reading a static initialiser
 * wants. This is for the other case: a mod scatters its recipe registrations across whatever
 * methods it likes, and which ones they are is not knowable in advance - so all of them are walked.
 *
 * The returned pointers are into `data`, which must outlive them.
 * @date 2026-09-17 */
inline std::vector<method_code_t> read_methods(const std::vector<uint8_t> &data,
        class_file_t &cf_out) {
    std::vector<method_code_t> out;
    cf_out = read_class(data, "");
    if (!cf_out.ok || data.size() < 24)
        return out;

    const uint8_t *d = data.data();
    size_t len = data.size();
    auto u2 = [&](size_t at) -> uint32_t {
        return (at + 1 < len) ? (uint32_t)((d[at] << 8) | d[at + 1]) : 0;
    };
    auto u4 = [&](size_t at) -> uint32_t {
        if (at + 3 >= len) return 0;
        return (uint32_t)((d[at] << 24) | (d[at + 1] << 16) | (d[at + 2] << 8) | d[at + 3]);
    };

    /* Walk to the methods again. The pool parse in read_class left no cursor behind, and a second
    walk is cheaper than threading one out of it. */
    size_t p = 10;
    uint32_t count = u2(8);
    for (uint32_t n = 1; n < count && p < len; n++) {
        uint8_t tag = d[p];
        switch (tag) {
            case 1: p += 3 + u2(p + 1); break;
            case 5: case 6: p += 9; n++; break;
            case 7: case 8: p += 3; break;
            case 15: p += 4; break;
            case 16: case 19: case 20: p += 3; break;
            default: p += 5; break;
        }
    }
    p += 6;
    p += 2 + 2u * u2(p);

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
        method_code_t m;
        m.name = cf_out.utf8(u2(p));
        p += 4;
        uint32_t ac = u2(p);
        p += 2;
        for (uint32_t k = 0; k < ac && p < len; k++) {
            const std::string &aname = cf_out.utf8(u2(p));
            uint32_t alen = u4(p + 2);
            if (aname == "Code") {
                m.len = u4(p + 6 + 4);
                if (p + 6 + 8 + m.len <= len)
                    m.code = d + p + 6 + 8;
                else
                    m.len = 0;
            }
            p += 6 + alen;
        }
        if (m.code && m.len)
            out.push_back(m);
    }
    return out;
}

} /* namespace class_reader */

#endif /* CLASS_READER_H */
