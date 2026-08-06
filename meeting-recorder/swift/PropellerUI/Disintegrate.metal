#include <metal_stdlib>

using namespace metal;

// MARK: - Пепел строки: инстансированные квады + физика в compute
//
// Одна частица на клетку строки. Строка один раз растрируется в текстуру, и
// каждая частица — квад, который семплит *свою* клетку этой текстуры. Значит
// хлопья несут настоящие пиксели букв, а не серые точки, и весь кадр — один
// draw call с `instanceCount`, а не тысяча заливок на CPU.
//
// Ручки живут в `Tokens.Motion.Ash`; здесь нет ни одного числа, которое стоило
// бы крутить.

struct AshParticle {
    packed_float2 offset;
    packed_float2 velocity;
    float lifetime;
    float _pad;
};

struct AshInitParams {
    float speedMin;
    float speedMax;
    float lifeMin;
    float lifeMax;
    uint  seed;
};

struct AshUpdateParams {
    uint2 grid;
    float phase;
    float timeStep;
    float waveWindow;
    float waveDuration;
    float gravity;
    float _pad;
};

struct AshDrawParams {
    float2 size;
    float2 canvas;
    float2 margin;
    uint2  grid;
    float  fadeTail;
    float  _pad;
};

struct AshVertexOut {
    float4 position [[position]];
    float2 uv;
    float  alpha;
};

constant static float2 quadVertices[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 1.0)
};

/// Целочисленный хеш — у частицы стабильная случайность без буфера сидов.
static inline uint ashHash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

static inline float ashRand(uint seed) {
    return float(ashHash(seed) & 0x00ffffffu) / float(0x01000000u);
}

kernel void ashInit(
    device AshParticle *particles [[ buffer(0) ]],
    constant AshInitParams &p [[ buffer(1) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    uint s = gid ^ p.seed;

    // Разлёт по всему кругу, а не в одну сторону: строка не сдувается ветром,
    // она осыпается. Направленность потом даёт гравитация.
    float angle = ashRand(s) * (3.14159265 * 2.0);
    float speed = mix(p.speedMin, p.speedMax, ashRand(s + 1u));

    AshParticle particle;
    particle.offset = packed_float2(0.0, 0.0);
    particle.velocity = packed_float2(cos(angle) * speed, sin(angle) * speed);
    particle.lifetime = mix(p.lifeMin, p.lifeMax, ashRand(s + 2u));
    particle._pad = 0.0;

    particles[gid] = particle;
}

/// Фронт волны слева направо.
///
/// Окно шириной `w` едет от левого края строки за её правый край за
/// `waveDuration`. Перед окном частица **заморожена** — не невидима, а
/// неподвижна; за окном летит в полную силу. Именно это читается как «строка
/// осыпается», а не «всё разом пыхнуло».
static inline float ashWaveGate(float xFraction, float waveProgress, float w) {
    float windowPos = mix(-w, 1.0, waveProgress);
    return 1.0 - saturate((xFraction - windowPos) / w);
}

kernel void ashUpdate(
    device AshParticle *particles [[ buffer(0) ]],
    constant AshUpdateParams &u [[ buffer(1) ]],
    uint gid [[ thread_position_in_grid ]]
) {
    uint count = u.grid.x * u.grid.y;
    if (gid >= count) {
        return;
    }

    float columns = float(max(1u, u.grid.x - 1u));
    float xFraction = float(gid % u.grid.x) / columns;
    float waveProgress = saturate(u.phase / max(0.0001, u.waveDuration));
    float gate = ashWaveGate(xFraction, waveProgress, u.waveWindow);

    AshParticle p = particles[gid];
    // Ворота множат и скорость, и гравитацию, и расход жизни: пока волна не
    // дошла, время для частицы не идёт вовсе.
    p.offset += p.velocity * u.timeStep * gate;
    p.velocity += float2(0.0, u.gravity * u.timeStep) * gate;
    p.lifetime = max(0.0, p.lifetime - u.timeStep * gate);
    particles[gid] = p;
}

vertex AshVertexOut ashVertex(
    constant AshDrawParams &d [[ buffer(0) ]],
    const device AshParticle *particles [[ buffer(1) ]],
    uint vid [[ vertex_id ]],
    uint iid [[ instance_id ]]
) {
    float2 quad = quadVertices[vid];

    uint ix = iid % d.grid.x;
    uint iy = iid / d.grid.x;
    float2 cell = d.size / float2(d.grid);
    float2 base = float2(float(ix), float(iy)) * cell;

    AshParticle p = particles[iid];

    // UV берётся от *исходной* клетки — частица уносит свой кусок текстуры.
    AshVertexOut out;
    out.uv = (base + quad * cell) / d.size;

    // Точки строки → точки холста → NDC. Y вниз, как в вёрстке.
    float2 local = base + float2(p.offset) + quad * cell + d.margin;
    float2 ndc = float2(local.x / d.canvas.x * 2.0 - 1.0,
                        1.0 - local.y / d.canvas.y * 2.0);
    out.position = float4(ndc, 0.0, 1.0);

    // Гаснет только последний хвост своей жизни — не мигает и не тает сразу.
    out.alpha = saturate(p.lifetime / max(0.0001, d.fadeTail));

    return out;
}

fragment half4 ashFragment(
    AshVertexOut in [[ stage_in ]],
    texture2d<half, access::sample> source [[ texture(0) ]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    half4 color = source.sample(s, in.uv);
    // Текстура premultiplied — множим целиком, чтобы такой и осталась.
    return color * half(in.alpha);
}
