#pragma once

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>

// Cached uniform locations for a compiled RetroArch-style CRT GLSL program.
struct CrtShaderProgram {
    GLuint prog = 0;
    GLint mvpMatrix = -1;
    GLint texture = -1;
    GLint origTexture = -1;
    GLint prevTexture = -1;
    GLint inputSize = -1;
    GLint textureSize = -1;
    GLint origInputSize = -1;
    GLint origTextureSize = -1;
    GLint prevInputSize = -1;
    GLint prevTextureSize = -1;
    GLint outputSize = -1;
    GLint frameCount = -1;
    GLint interlaced = -1;
    GLint hvBloom = -1;
    GLint curvature = -1;
    GLint maskStrength = -1;
    GLint rfSnow = -1;
    GLint rfSignal = -1;
    GLint rfStandbySnow = -1;
    GLint powerJitter = -1;
};

namespace crt_gl {

CrtShaderProgram linkBundledShaderProgram(NSString *shaderName, const char *label);
void destroyShaderProgram(CrtShaderProgram &shader);
GLuint createFrameTexture();
void uploadOrUpdateRgbaTexture(GLuint &tex, int width, int height, const void *rgbaPixels, bool recreate);
void drawFullscreenQuad();
void drawColorOverlayQuad(float r, float g, float b, float a);
void drawOrthoTexturedQuad(GLuint tex,
                           GLsizei viewW, GLsizei viewH,
                           float x, float y, float w, float h,
                           float alpha, bool premultipliedAlpha);

inline void uploadIdentityMvp(const CrtShaderProgram &shader) {
    static const float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    if (shader.mvpMatrix >= 0) glUniformMatrix4fv(shader.mvpMatrix, 1, GL_FALSE, identity);
}

inline void setUniform1i(GLint loc, GLint v) { if (loc >= 0) glUniform1i(loc, v); }
inline void setUniform1f(GLint loc, GLfloat v) { if (loc >= 0) glUniform1f(loc, v); }
inline void setUniform2f(GLint loc, GLfloat x, GLfloat y) { if (loc >= 0) glUniform2f(loc, x, y); }

} // namespace crt_gl
