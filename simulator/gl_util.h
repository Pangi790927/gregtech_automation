#ifndef GL_UTIL_H
#define GL_UTIL_H

/*! gl_util.h - the thin OpenGL layer the 3D view is drawn with: a matrix type, a shader program, a
 * texture and an indexed mesh. Plain C++, no Lua anywhere in this file.
 *
 * Core: everything here is the minimum needed to put textured cubes on screen, and nothing else. It
 * is the bottom of the drawing stack - render_composer.h sits on it and exposes a shaped API to
 * Lua, the way char_draw_composer.h sits on its own drawing primitives in math_writer.
 *
 * Where the GL entry points come from: ImGui already embeds a stripped gl3w
 * (imgui/backends/imgui_impl_opengl3_loader.h) and already calls imgl3wInit() inside
 * ImGui_ImplOpenGL3_Init(). Including that header here without IMGL3W_IMPL gives the declarations,
 * and the `imgl3wProcs` symbol resolves against ImGui's own translation unit at link time - so the
 * project gains modern GL without gaining a dependency. Two consequences follow, and both are
 * load-bearing:
 *
 *   - No GL call in this file may run before imgui_init(). The procs are null until then.
 *   - Only the entry points that stripped loader carries exist. glDrawArrays is not among them,
 *     which is why every mesh here is indexed and drawn with glDrawElements.
 *
 * The context is whatever imgui_helpers.h asked GLFW for, which on Windows and Linux is GL 3.0 with
 * GLSL 130 and no core-profile hint. That is why the shaders in render_composer.h are `#version
 * 130` and bind their attributes through glGetAttribLocation rather than a `layout(location = ...)`
 * qualifier, which needs GLSL 330.
 *
 * @date 2026-09-16 */

#include "imgui_impl_opengl3_loader.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "debug.h"

/* Two constants the stripped loader does not carry - it keeps only what ImGui itself references.
Their values are fixed by the GL specification and are the same on every implementation. */
#ifndef GL_DEPTH_BUFFER_BIT
#define GL_DEPTH_BUFFER_BIT 0x00000100
#endif
#ifndef GL_STATIC_DRAW
#define GL_STATIC_DRAW 0x88E4
#endif

namespace gl_util {

/*! A 4x4 matrix in column-major order, which is the order glUniformMatrix4fv reads without
 * transposing. `m[c * 4 + r]` is column c, row r.
 *
 * Deliberately not a general linear algebra type: it carries multiplication and the two
 * constructors the camera needs, because that is all the renderer asks of it.
 *
 * @date 2026-09-16 */
struct mat4_t {
    float m[16] = {1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1};

    /*! The product `a * b`, which applied to a column vector applies b first. @date 2026-09-16 */
    static mat4_t mul(const mat4_t &a, const mat4_t &b) {
        mat4_t r;
        for (int c = 0; c < 4; c++)
            for (int row = 0; row < 4; row++) {
                float sum = 0;
                for (int k = 0; k < 4; k++)
                    sum += a.m[k * 4 + row] * b.m[c * 4 + k];
                r.m[c * 4 + row] = sum;
            }
        return r;
    }

    /*! A right-handed perspective projection mapping depth into the range -1 to 1.
     *
     * Params: `fov_y` in radians, `aspect` as width over height, and the two clip distances.
     * @date 2026-09-16 */
    static mat4_t perspective(float fov_y, float aspect, float z_near, float z_far) {
        mat4_t r;
        memset(r.m, 0, sizeof(r.m));
        float f = 1.0f / std::tan(fov_y * 0.5f);
        r.m[0]  = f / aspect;
        r.m[5]  = f;
        r.m[10] = (z_far + z_near) / (z_near - z_far);
        r.m[11] = -1.0f;
        r.m[14] = (2.0f * z_far * z_near) / (z_near - z_far);
        return r;
    }

    /*! A view matrix for a camera at `eye` looking along `fwd`, with `up` fixing the roll.
     *
     * Neither `fwd` nor `up` need be a unit vector and they need not be perpendicular: both are
     * normalised here and the right vector is rebuilt from their cross product, so a caller may
     * hand over a raw yaw and pitch direction together with a constant world up.
     * @date 2026-09-16 */
    static mat4_t look_dir(const float eye[3], const float fwd[3], const float up[3]) {
        float f[3] = {fwd[0], fwd[1], fwd[2]};
        normalise(f);

        float s[3];
        cross(f, up, s);
        normalise(s);

        float u[3];
        cross(s, f, u);

        mat4_t r;
        r.m[0] = s[0];  r.m[4] = s[1];  r.m[8]  = s[2];
        r.m[1] = u[0];  r.m[5] = u[1];  r.m[9]  = u[2];
        r.m[2] = -f[0]; r.m[6] = -f[1]; r.m[10] = -f[2];
        r.m[12] = -dot(s, eye);
        r.m[13] = -dot(u, eye);
        r.m[14] = dot(f, eye);
        return r;
    }

    /*! A uniform scale about the origin followed by a translation - the model matrix for something
     * built once at unit size around the origin and then put somewhere.
     *
     * It exists because the marker sphere is drawn that way. The alternative, an offset uniform
     * added in the vertex shader, would need glUniform3f, and that is not among the entry points
     * ImGui's embedded loader carries; folding the move into the matrix uses glUniformMatrix4fv,
     * which is.
     * @date 2026-09-16 */
    static mat4_t translate_scale(float x, float y, float z, float scale) {
        mat4_t r;
        r.m[0] = scale; r.m[5] = scale; r.m[10] = scale;
        r.m[12] = x; r.m[13] = y; r.m[14] = z;
        return r;
    }

    static float dot(const float a[3], const float b[3]) {
        return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    }

    static void cross(const float a[3], const float b[3], float out[3]) {
        out[0] = a[1] * b[2] - a[2] * b[1];
        out[1] = a[2] * b[0] - a[0] * b[2];
        out[2] = a[0] * b[1] - a[1] * b[0];
    }

    /*! Scales `v` to unit length in place, leaving a zero vector alone rather than making NaNs.
     * @date 2026-09-16 */
    static void normalise(float v[3]) {
        float len = std::sqrt(dot(v, v));
        if (len <= 1e-8f)
            return;
        v[0] /= len; v[1] /= len; v[2] /= len;
    }
};

/*! A linked vertex and fragment program, with the uniform and attribute lookups the renderer needs.
 *
 * Core: compile() builds the program and caches nothing. A failed compile or link logs the driver's
 * own message and leaves `prog` at zero, which every other call here treats as "do nothing" - a
 * shader that will not build should cost a blank view and a line in the log, not a crash.
 *
 * @date 2026-09-16 */
struct shader_t {
    uint32_t prog = 0;

    /*! Builds the program from two GLSL sources. Returns true when it linked. @date 2026-09-16 */
    bool compile(const char *vert_src, const char *frag_src) {
        uint32_t vert = compile_stage(GL_VERTEX_SHADER, vert_src);
        uint32_t frag = compile_stage(GL_FRAGMENT_SHADER, frag_src);
        if (!vert || !frag) {
            if (vert) glDeleteShader(vert);
            if (frag) glDeleteShader(frag);
            return false;
        }

        prog = glCreateProgram();
        glAttachShader(prog, vert);
        glAttachShader(prog, frag);
        glLinkProgram(prog);

        int ok = 0;
        glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (!ok) {
            char log[1024] = {};
            glGetProgramInfoLog(prog, sizeof(log) - 1, nullptr, log);
            DBG("shader link failed: %s", log);
            glDeleteProgram(prog);
            prog = 0;
        }

        /* Detaching lets the driver drop the stage objects once the program owns the compiled code.
        Skipped on a failed link, where there is no program left to detach from. */
        if (prog) {
            glDetachShader(prog, vert);
            glDetachShader(prog, frag);
        }
        glDeleteShader(vert);
        glDeleteShader(frag);
        return prog != 0;
    }

    void use() const { if (prog) glUseProgram(prog); }

    int uniform(const char *name) const {
        return prog ? glGetUniformLocation(prog, name) : -1;
    }

    int attribute(const char *name) const {
        return prog ? glGetAttribLocation(prog, name) : -1;
    }

    void destroy() {
        if (prog)
            glDeleteProgram(prog);
        prog = 0;
    }

private:
    /*! Compiles one stage, answering its name, or zero after logging the driver's diagnostic.
     * @date 2026-09-16 */
    static uint32_t compile_stage(uint32_t stage, const char *src) {
        uint32_t sh = glCreateShader(stage);
        glShaderSource(sh, 1, &src, nullptr);
        glCompileShader(sh);

        int ok = 0;
        glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[1024] = {};
            glGetShaderInfoLog(sh, sizeof(log) - 1, nullptr, log);
            DBG("shader compile failed (%s): %s",
                    stage == GL_VERTEX_SHADER ? "vertex" : "fragment", log);
            glDeleteShader(sh);
            return 0;
        }
        return sh;
    }
};

/*! An RGBA texture with nearest-neighbour filtering and clamped edges.
 *
 * Nearest filtering is the point here rather than a default: these are 16x16 Minecraft tiles, and
 * the whole look depends on them staying blocky when magnified. Clamping matters because the atlas
 * packs many tiles into one image, where GL_REPEAT would let a face sample its neighbour.
 *
 * @date 2026-09-16 */
struct texture_t {
    uint32_t tex = 0;
    int w = 0;
    int h = 0;

    /*! Uploads `width * height` RGBA bytes, replacing whatever this texture held.
     * @date 2026-09-16 */
    void upload(int width, int height, const uint8_t *rgba) {
        if (!tex)
            glGenTextures(1, &tex);
        w = width;
        h = height;

        glBindTexture(GL_TEXTURE_2D, tex);
        /* The atlas rows are tightly packed and its width need not be a multiple of four. */
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
        glBindTexture(GL_TEXTURE_2D, 0);
    }

    void bind(int unit) const {
        glActiveTexture(GL_TEXTURE0 + unit);
        glBindTexture(GL_TEXTURE_2D, tex);
    }

    void destroy() {
        if (tex)
            glDeleteTextures(1, &tex);
        tex = 0;
        w = h = 0;
    }
};

/*! One vertex of the world mesh: a position, an atlas coordinate and a brightness.
 *
 * `shade` is per-vertex rather than computed in the shader because the only lighting here is
 * Minecraft's - a fixed brightness per face direction - and baking it costs one float where a
 * normal would cost three floats and a dot product.
 *
 * @date 2026-09-16 */
struct vertex_t {
    float x, y, z;
    float u, v;
    /*! The colour this vertex multiplies its texel by.
     *
     * It was one float, a plain brightness, until the tanks needed it: GregTech keeps no picture
     * for most of its fluids and draws them by tinting a greyscale image with the material's own
     * colour. Three floats instead of one means the same mesh can carry both - a face's baked
     * brightness is simply the same number three times.
     * @date 2026-09-17 */
    float tr, tg, tb;
};

/*! An indexed triangle mesh living in one vertex buffer and one index buffer.
 *
 * Core: upload() replaces the whole contents and draw() draws all of it. There is no partial update
 * and no streaming - the world mesh is rebuilt wholesale whenever the world changes, which at this
 * size costs less than tracking which parts of it went stale.
 *
 * A vertex array object is bound on every draw. GL 3.0 has them in core, but the context
 * imgui_helpers.h asks for carries no core-profile hint, so a compatibility context may also accept
 * attribute state without one; binding explicitly keeps both paths correct.
 *
 * @date 2026-09-16 */
struct mesh_t {
    uint32_t vao = 0;
    uint32_t vbo = 0;
    uint32_t ibo = 0;
    int index_count = 0;

    /*! Replaces the mesh contents. An empty vertex or index list leaves a mesh that draws nothing.
     * @date 2026-09-16 */
    void upload(const std::vector<vertex_t> &verts, const std::vector<uint32_t> &indices) {
        if (!vao) glGenVertexArrays(1, &vao);
        if (!vbo) glGenBuffers(1, &vbo);
        if (!ibo) glGenBuffers(1, &ibo);

        index_count = (int)indices.size();

        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, (ptrdiff_t)(verts.size() * sizeof(vertex_t)),
                verts.empty() ? nullptr : verts.data(), GL_STATIC_DRAW);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, (ptrdiff_t)(indices.size() * sizeof(uint32_t)),
                indices.empty() ? nullptr : indices.data(), GL_STATIC_DRAW);
        glBindVertexArray(0);
    }

    /*! Points the three attributes at their fields and draws every index.
     *
     * The attribute locations are passed in rather than stored, because they belong to the shader
     * and not to the mesh, and the same mesh may be drawn by more than one program. A location of
     * -1 - what glGetAttribLocation answers for an attribute the linker dropped - is skipped.
     * @date 2026-09-16 */
    void draw(int loc_pos, int loc_uv, int loc_tint) const {
        if (!index_count || !vao)
            return;

        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);

        if (loc_pos >= 0) {
            glEnableVertexAttribArray(loc_pos);
            glVertexAttribPointer(loc_pos, 3, GL_FLOAT, GL_FALSE, sizeof(vertex_t),
                    (void *)offsetof(vertex_t, x));
        }
        if (loc_uv >= 0) {
            glEnableVertexAttribArray(loc_uv);
            glVertexAttribPointer(loc_uv, 2, GL_FLOAT, GL_FALSE, sizeof(vertex_t),
                    (void *)offsetof(vertex_t, u));
        }
        if (loc_tint >= 0) {
            glEnableVertexAttribArray(loc_tint);
            glVertexAttribPointer(loc_tint, 3, GL_FLOAT, GL_FALSE, sizeof(vertex_t),
                    (void *)offsetof(vertex_t, tr));
        }

        glDrawElements(GL_TRIANGLES, index_count, GL_UNSIGNED_INT, nullptr);

        if (loc_pos >= 0)   glDisableVertexAttribArray(loc_pos);
        if (loc_uv >= 0)    glDisableVertexAttribArray(loc_uv);
        if (loc_tint >= 0) glDisableVertexAttribArray(loc_tint);
        glBindVertexArray(0);
    }

    void destroy() {
        if (ibo) glDeleteBuffers(1, &ibo);
        if (vbo) glDeleteBuffers(1, &vbo);
        if (vao) glDeleteVertexArrays(1, &vao);
        vao = vbo = ibo = 0;
        index_count = 0;
    }
};

} /* namespace gl_util */

#endif /* GL_UTIL_H */
