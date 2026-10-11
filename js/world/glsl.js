// Shared GLSL for the landscape: noise, the time of day across the screen, and the air (the sky's colours).
// Every shader of the scene asks the same question, dayAt(pixel): 0 is Khanjar's night, 1 Isma Organizer's day.

export const NOISE = /* glsl */`
float hash12(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * .1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
vec2 hash22(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * vec3(.1031, .1030, .0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }
float vnoise(vec2 p){
  vec2 i = floor(p), f = fract(p), u = f * f * (3. - 2. * f);
  return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p){ float a = .5, s = 0.; for (int i = 0; i < 4; i++){ s += a * vnoise(p); p = p * 2.03 + 17.1; a *= .5; } return s; }
`;

// uSeam, desktop: x = the seam at the top of the screen, y = at the bottom (0..1 from the left), z / w = half band at top / bottom.
// uSeam, phone: x = the border between the two sections (0..1 from the top of the screen), z = half band.
export const TOD = /* glsl */`
uniform vec2 uRes;
uniform vec4 uSeam;
uniform float uMode, uTime;
// signed distance to the seam, in screen fractions: < 0 on the night side
float seamDist(vec2 fc){
  vec2 q = fc / uRes;
  if (uMode < .5) return q.x - mix(uSeam.y, uSeam.x, q.y) + .006 * sin(q.y * 7. + uTime * .21);
  return (1. - q.y) - uSeam.x + .004 * sin(q.x * 6. + uTime * .27);
}
float bandAt(vec2 fc){ return uMode < .5 ? mix(uSeam.w, uSeam.z, fc.y / uRes.y) : uSeam.z; }
float dayAt(vec2 fc){ float b = bandAt(fc); return smoothstep(-b, b, seamDist(fc)); }
`;

// the air, by height above the horizon e (0 at the horizon, 1 at the top of the frame), in sRGB
export const SKY = /* glsl */`
uniform vec3 uLavaAir;   // where the lava warms the air: azimuth, width (radians), strength
vec3 nightAir(float e){                                                                    // moonlit night
  vec3 c = mix(vec3(.13, .135, .22), vec3(.055, .06, .105), smoothstep(0., .16, e));      // blue-violet haze low down
  c = mix(c, vec3(.022, .026, .05), smoothstep(.1, .48, e));
  return mix(c, vec3(.008, .01, .022), smoothstep(.45, 1., e));
}
vec3 dayAir(float e){                                                                      // Isma Organizer's sky
  vec3 c = mix(vec3(.94, .984, 1.), vec3(.84, .945, 1.), smoothstep(0., .1, e));
  c = mix(c, vec3(.608, .839, .984), smoothstep(.06, .26, e));
  c = mix(c, vec3(.345, .682, .945), smoothstep(.2, .44, e));
  c = mix(c, vec3(.176, .553, .902), smoothstep(.4, .62, e));
  c = mix(c, vec3(.082, .439, .839), smoothstep(.58, .82, e));
  return mix(c, vec3(.039, .345, .741), smoothstep(.78, 1., e));
}
vec3 glowCol(float h){                                       // the sunset, from the horizon up: gold, orange, pink, violet
  vec3 c = mix(vec3(1., .82, .5), vec3(1., .56, .3), smoothstep(0., .05, h));
  c = mix(c, vec3(.93, .43, .44), smoothstep(.04, .15, h));
  return mix(c, vec3(.36, .27, .55), smoothstep(.13, .32, h));
}
// d: time of day, s: distance to the seam (screen fraction, < 0 on the night side), e: height, az: azimuth
vec3 airAt(float d, float s, float e, float az){
  vec3 c = mix(nightAir(e), dayAir(e), d);
  float mid = 1. - abs(2. * d - 1.);
  c = mix(c, vec3(.1, .12, .27), mid * .6 * smoothstep(.12, .7, e));          // high up, the change is a quiet blue-violet
  c += vec3(.3, .075, .028) * uLavaAir.z * exp(-e / .065) * exp(-pow((az - uLavaAir.x) / uLavaAir.y, 2.)) * (1. - d);
  if (uMode < .5){                                                             // computer: the glow hugs the horizon,
    float g = exp(-s * s / .024);                                              // widest and brightest at the seam
    float h = e / (.45 + .75 * g);
    return mix(c, glowCol(h), clamp(g * exp(-h / .11) * .95, 0., 1.));
  }
  // phone: the dusk rides on the border between the sections, one continuous ramp:
  // night, violet, pink, gold on the border, pale gold, day
  float u = s / .12;
  vec3 glow = u < 0. ? mix(mix(vec3(1., .76, .46), vec3(.93, .43, .44), smoothstep(0., -.55, u)), vec3(.36, .27, .55), smoothstep(-.45, -1.25, u))
                     : mix(vec3(1., .76, .46), vec3(1., .9, .76), smoothstep(0., .6, u));
  return mix(c, glow, exp(-u * u * (u < 0. ? 1. : 2.4)) * .92);
}
vec3 toLin(vec3 c){ return pow(max(c, 0.), vec3(2.2)); }
vec3 toSRGB(vec3 c){ return pow(max(c, 0.), vec3(1. / 2.2)); }
`;
