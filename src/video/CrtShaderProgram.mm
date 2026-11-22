#import "CrtShaderProgram.hpp"

#include <cstdio>
#include <string>
#include <vector>

namespace crt_gl {

namespace {

std::string loadBundledShader(NSString *shaderName) {
    NSString *path = [[NSBundle mainBundle] pathForResource:shaderName ofType:@"glsl" inDirectory:@"shaders"];
    if (!path) {
        std::fprintf(stderr, "Missing shader resource: %s.glsl\n", [shaderName UTF8String]);
        return "";
    }
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return text ? std::string([text UTF8String]) : "";
}

// RetroArch-style single-file shaders switch between VERTEX and FRAGMENT sections via #define.
std::string injectDefinesAfterVersion(const std::string &source, const std::string &defines) {
    const size_t firstNewline = source.find('\n');
    if (firstNewline == std::string::npos) return defines + "\n" + source;
    return source.substr(0, firstNewline + 1) + defines + "\n" + source.substr(firstNewline + 1);
}

GLuint compileShaderStage(GLenum stageType, const std::string &source, const char *label) {
    GLuint shader = glCreateShader(stageType);
    const char *raw = source.c_str();
    glShaderSource(shader, 1, &raw, nullptr);
    glCompileShader(shader);

    GLint status = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        char infoLog[4096] = {0};
        glGetShaderInfoLog(shader, sizeof(infoLog) - 1, nullptr, infoLog);
        std::fprintf(stderr, "Shader compile error (%s):\n%s\n", label, infoLog);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

} // namespace

CrtShaderProgram linkBundledShaderProgram(NSString *shaderName, const char *label) {
    CrtShaderProgram result{};
    const std::string source = loadBundledShader(shaderName);
    if (source.empty()) return result;

    GLuint vertexShader = compileShaderStage(
        GL_VERTEX_SHADER,
        injectDefinesAfterVersion(source, "#define VERTEX\n#define PARAMETER_UNIFORM\n"),
        label);
    GLuint fragmentShader = compileShaderStage(
        GL_FRAGMENT_SHADER,
        injectDefinesAfterVersion(source, "#define FRAGMENT\n#define PARAMETER_UNIFORM\n"),
        label);
    if (!vertexShader || !fragmentShader) {
        if (vertexShader) glDeleteShader(vertexShader);
        if (fragmentShader) glDeleteShader(fragmentShader);
        return result;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vertexShader);
    glAttachShader(program, fragmentShader);
    glBindAttribLocation(program, 0, "VertexCoord");
    glBindAttribLocation(program, 1, "TexCoord");
    glLinkProgram(program);
    glDeleteShader(vertexShader);
    glDeleteShader(fragmentShader);

    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char infoLog[4096] = {0};
        glGetProgramInfoLog(program, sizeof(infoLog) - 1, nullptr, infoLog);
        std::fprintf(stderr, "Shader link error (%s):\n%s\n", label, infoLog);
        glDeleteProgram(program);
        return result;
    }

    result.prog = program;
    result.mvpMatrix = glGetUniformLocation(program, "MVPMatrix");
    result.texture = glGetUniformLocation(program, "Texture");
    result.origTexture = glGetUniformLocation(program, "OrigTexture");
    result.prevTexture = glGetUniformLocation(program, "PrevTexture");
    result.inputSize = glGetUniformLocation(program, "InputSize");
    result.textureSize = glGetUniformLocation(program, "TextureSize");
    result.origInputSize = glGetUniformLocation(program, "OrigInputSize");
    result.origTextureSize = glGetUniformLocation(program, "OrigTextureSize");
    result.prevInputSize = glGetUniformLocation(program, "PrevInputSize");
    result.prevTextureSize = glGetUniformLocation(program, "PrevTextureSize");
    result.outputSize = glGetUniformLocation(program, "OutputSize");
    result.frameCount = glGetUniformLocation(program, "FrameCount");
    result.interlaced = glGetUniformLocation(program, "OKUSAN_INTERLACED");
    result.hvBloom = glGetUniformLocation(program, "OKUSAN_HV_BLOOM");
    result.curvature = glGetUniformLocation(program, "OKUSAN_CURVATURE");
    result.maskStrength = glGetUniformLocation(program, "OKUSAN_MASK_STRENGTH");
    result.rfSnow = glGetUniformLocation(program, "OKUSAN_RF_SNOW");
    result.rfSignal = glGetUniformLocation(program, "OKUSAN_RF_SIGNAL");
    result.rfStandbySnow = glGetUniformLocation(program, "OKUSAN_RF_STANDBY_SNOW");
    result.powerJitter = glGetUniformLocation(program, "OKUSAN_POWER_JITTER");
    return result;
}

void destroyShaderProgram(CrtShaderProgram &shader) {
    if (shader.prog) {
        glDeleteProgram(shader.prog);
        shader.prog = 0;
    }
}

GLuint createFrameTexture() {
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    std::vector<uint32_t> blank(512 * 256, 0xFF000000u);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 512, 256, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, blank.data());
    return tex;
}

void uploadOrUpdateRgbaTexture(GLuint &tex, int width, int height, const void *rgbaPixels, bool recreate) {
    glActiveTexture(GL_TEXTURE0);
    if (!tex) {
        glGenTextures(1, &tex);
        recreate = true;
    }
    glBindTexture(GL_TEXTURE_2D, tex);
    if (recreate) {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgbaPixels);
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgbaPixels);
    }
}

void drawFullscreenQuad() {
    static const float vertices[4][2] = {{-1.f, -1.f}, {1.f, -1.f}, {-1.f, 1.f}, {1.f, 1.f}};
    static const float texCoords[4][2] = {{0.f, 0.f}, {1.f, 0.f}, {0.f, 1.f}, {1.f, 1.f}};
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, texCoords);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
}

void drawColorOverlayQuad(float r, float g, float b, float a) {
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glOrtho(0.0, 1.0, 0.0, 1.0, -1.0, 1.0);
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glColor4f(r, g, b, a);
    glBegin(GL_QUADS);
    glVertex2f(0.0f, 0.0f);
    glVertex2f(1.0f, 0.0f);
    glVertex2f(1.0f, 1.0f);
    glVertex2f(0.0f, 1.0f);
    glEnd();
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    glDisable(GL_BLEND);
    glPopMatrix();
    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
    glMatrixMode(GL_MODELVIEW);
}

void drawOrthoTexturedQuad(GLuint tex,
                           GLsizei viewW, GLsizei viewH,
                           float x, float y, float w, float h,
                           float alpha, bool premultipliedAlpha) {
    glViewport(0, 0, viewW, viewH);
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glOrtho(0.0, static_cast<double>(viewW), 0.0, static_cast<double>(viewH), -1.0, 1.0);
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();

    glEnable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, tex);
    glEnable(GL_BLEND);
    glBlendFunc(premultipliedAlpha ? GL_ONE : GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    if (premultipliedAlpha) {
        glColor4f(alpha, alpha, alpha, alpha);
    } else {
        glColor4f(1.0f, 1.0f, 1.0f, alpha);
    }

    glBegin(GL_QUADS);
    glTexCoord2f(0.0f, 1.0f); glVertex2f(x, y);
    glTexCoord2f(1.0f, 1.0f); glVertex2f(x + w, y);
    glTexCoord2f(1.0f, 0.0f); glVertex2f(x + w, y + h);
    glTexCoord2f(0.0f, 0.0f); glVertex2f(x, y + h);
    glEnd();

    glDisable(GL_BLEND);
    glDisable(GL_TEXTURE_2D);
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    glPopMatrix();
    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
    glMatrixMode(GL_MODELVIEW);
}

} // namespace crt_gl
