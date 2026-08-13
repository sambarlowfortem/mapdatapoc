shader_type spatial;

// Baked top-down render of the ground/line meshes (see
// MVTTileRenderer._generate_and_apply_ground_texture) blended onto the
// terrain surface by world-space position rather than mesh UVs, so the
// same material/uniforms work for every terrain tile at once regardless of
// its own local offset.
uniform sampler2D ground_texture : source_color;
uniform vec2 bbox_min;
uniform vec2 bbox_size;
uniform vec3 base_color : source_color;

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
}
