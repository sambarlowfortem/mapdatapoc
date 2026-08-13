shader_type spatial;

// Baked top-down texture(s) blended onto the terrain surface by world-space
// position rather than mesh UVs, so the same material/uniforms work for
// every terrain tile at once regardless of its own local offset. Two
// independent layers, each with its own world-space bounding box: a base
// layer (see MVTTileRenderer._build_and_apply_ground_texture or
// SatelliteTileLoader's low-res whole-terrain background) that normally
// covers the full terrain grid, and an optional overlay layer (see
// SatelliteTileLoader's high-res center pyramid) drawn on top of it
// wherever the overlay's own bbox covers - lets a small high-detail patch
// sit over a much larger low-detail background without baking both into
// one texture at a single shared resolution.
uniform sampler2D ground_texture : source_color;
uniform vec2 bbox_min;
uniform vec2 bbox_size;
uniform vec3 base_color : source_color;

uniform sampler2D overlay_texture : source_color;
uniform vec2 overlay_bbox_min;
uniform vec2 overlay_bbox_size;
uniform bool overlay_enabled = false;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 uv = (world_xz - bbox_min) / bbox_size;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		ALBEDO = base_color;
	} else {
		vec4 tex_color = texture(ground_texture, uv);
		ALBEDO = mix(base_color, tex_color.rgb, tex_color.a);
	}

	if (overlay_enabled) {
		vec2 ouv = (world_xz - overlay_bbox_min) / overlay_bbox_size;
		if (ouv.x >= 0.0 && ouv.x <= 1.0 && ouv.y >= 0.0 && ouv.y <= 1.0) {
			vec4 overlay_color = texture(overlay_texture, ouv);
			ALBEDO = mix(ALBEDO, overlay_color.rgb, overlay_color.a);
		}
	}
}
