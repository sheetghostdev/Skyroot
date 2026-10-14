class_name Tex
extends RefCounted
## Shared, cached procedural textures (seamless noise) used by the shaders.

static var _cache: Dictionary = {}


static func noise(key: String, size: int, freq: float, octaves: int = 4, as_normal: bool = false, bump: float = 6.0, seed_value: int = 7, cellular: bool = false) -> NoiseTexture2D:
	var k := "%s_%d_%f_%d_%s" % [key, size, freq, octaves, as_normal]
	if _cache.has(k):
		return _cache[k]
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = freq
	n.fractal_octaves = octaves
	if cellular:
		n.noise_type = FastNoiseLite.TYPE_CELLULAR
		n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	else:
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	var t := NoiseTexture2D.new()
	t.width = size
	t.height = size
	t.seamless = true
	t.seamless_blend_skirt = 0.15
	t.noise = n
	t.generate_mipmaps = true
	if as_normal:
		t.as_normal_map = true
		t.bump_strength = bump
	else:
		t.normalize = true
	_cache[k] = t
	return t


static func noise_a() -> NoiseTexture2D:
	return noise("a", 512, 0.008, 4, false, 6.0, 11)


static func noise_b() -> NoiseTexture2D:
	return noise("b", 256, 0.03, 4, false, 6.0, 23)


static func noise_normal() -> NoiseTexture2D:
	return noise("n", 256, 0.05, 3, true, 5.0, 31)


static func wave_a() -> NoiseTexture2D:
	return noise("wa", 256, 0.02, 3, true, 3.0, 41)


static func wave_b() -> NoiseTexture2D:
	return noise("wb", 256, 0.045, 3, true, 2.0, 53)


static func clouds() -> NoiseTexture2D:
	return noise("cl", 512, 0.006, 5, false, 6.0, 61)


static func clouds_detail() -> NoiseTexture2D:
	return noise("cd", 256, 0.02, 4, false, 6.0, 67)


static func cells() -> NoiseTexture2D:
	return noise("ce", 256, 0.04, 1, false, 6.0, 71, true)


static func shader(path: String) -> Shader:
	if _cache.has(path):
		return _cache[path]
	var s: Shader = load(path)
	_cache[path] = s
	return s


static func gradient_tex(colors: Array, offsets: Array = []) -> GradientTexture1D:
	var g := Gradient.new()
	g.colors = PackedColorArray(colors)
	if offsets.size() == colors.size():
		g.offsets = PackedFloat32Array(offsets)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t
