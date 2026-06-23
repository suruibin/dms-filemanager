#version 440
layout(location=0) in vec2 qt_TexCoord0;
layout(location=0) out vec4 fragColor;
layout(std140, binding=0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;
};
uniform sampler2D source1;
uniform sampler2D source2;
void main() {
    vec2 uv = qt_TexCoord0 - 0.5;
    float angle = atan(uv.y, uv.x) + progress * 6.28;
    float dist = length(uv);
    float sweep = (angle / 6.28 + 0.5);
    float reveal = progress * 1.2;
    float edge = smoothstep(reveal - 0.1, reveal + 0.1, sweep) * smoothstep(0.0, 0.3, dist);
    fragColor = mix(texture(source1, uv + 0.5), texture(source2, uv + 0.5), edge);
    fragColor *= qt_Opacity;
}
