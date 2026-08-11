## Minimal Mapbox Vector Tile (MVT) / protobuf parser.
## No external dependencies - hand-rolled protobuf varint/message decoding
## specific to the MVT spec (https://github.com/mapbox/vector-tile-spec).
##
## Usage:
##   var layers = MVTParser.parse_tile(file_bytes)
##   # layers is a Dictionary: layer_name -> { "extent": int, "features": Array }
##   # each feature is { "type": int (1=POINT,2=LINESTRING,3=POLYGON),
##   #                    "rings": Array[PackedVector2Array], "props": Dictionary }
extends RefCounted
class_name MVTParser

const GEOM_POINT := 1
const GEOM_LINESTRING := 2
const GEOM_POLYGON := 3

# --- low level protobuf ------------------------------------------------

static func _read_varint(data: PackedByteArray, pos: int) -> Array:
	var result := 0
	var shift := 0
	while true:
		var b: int = data[pos]
		pos += 1
		result |= (b & 0x7F) << shift
		if not (b & 0x80):
			break
		shift += 7
	return [result, pos]

static func _zigzag(n: int) -> int:
	return (n >> 1) ^ (-(n & 1))

## Generic protobuf message parse: returns Dictionary field_num -> Array of raw values.
## Length-delimited fields come back as PackedByteArray; varint/32/64 as int.
static func _parse_message(data: PackedByteArray) -> Dictionary:
	var fields := {}
	var pos := 0
	var n := data.size()
	while pos < n:
		var kv = _read_varint(data, pos)
		var key: int = kv[0]
		pos = kv[1]
		var field_num := key >> 3
		var wire_type := key & 0x7
		var val
		match wire_type:
			0:
				var vv = _read_varint(data, pos)
				val = vv[0]
				pos = vv[1]
			1:
				val = data.slice(pos, pos + 8)
				pos += 8
			2:
				var lv = _read_varint(data, pos)
				var length: int = lv[0]
				pos = lv[1]
				val = data.slice(pos, pos + length)
				pos += length
			5:
				val = data.slice(pos, pos + 4)
				pos += 4
			_:
				push_error("MVTParser: unknown wire type %d" % wire_type)
				return fields
		if not fields.has(field_num):
			fields[field_num] = []
		fields[field_num].append(val)
	return fields

static func _parse_packed_varints(b: PackedByteArray) -> Array:
	var vals := []
	var pos := 0
	while pos < b.size():
		var vv = _read_varint(b, pos)
		vals.append(vv[0])
		pos = vv[1]
	return vals

## MVT "Value" message: a tagged union, only one field will be set.
static func _parse_value(b: PackedByteArray):
	var f := _parse_message(b)
	if f.has(1):
		return (f[1][0] as PackedByteArray).get_string_from_utf8()
	if f.has(2):
		return (f[2][0] as PackedByteArray).decode_float(0)
	if f.has(3):
		return (f[3][0] as PackedByteArray).decode_double(0)
	if f.has(4):
		return f[4][0]
	if f.has(5):
		return f[5][0]
	if f.has(6):
		return _zigzag(f[6][0])
	if f.has(7):
		return bool(f[7][0])
	return null

# --- geometry decoding ---------------------------------------------------

## Decodes the MVT geometry command stream into a list of point rings.
## Coordinates stay in tile-local integer space (0..extent, plus buffer).
static func _decode_geometry(cmds: Array) -> Array:
	var x := 0
	var y := 0
	var rings: Array = []
	var cur := PackedVector2Array()
	var i := 0
	while i < cmds.size():
		var cmd_int: int = cmds[i]
		i += 1
		var cmd_id := cmd_int & 0x7
		var cmd_count := cmd_int >> 3
		if cmd_id == 1 or cmd_id == 2:  # MoveTo / LineTo
			for _c in range(cmd_count):
				var dx = _zigzag(cmds[i]); i += 1
				var dy = _zigzag(cmds[i]); i += 1
				x += dx
				y += dy
				if cmd_id == 1 and cur.size() > 0:
					rings.append(cur)
					cur = PackedVector2Array()
				cur.append(Vector2(x, y))
		elif cmd_id == 7:  # ClosePath
			if cur.size() > 0:
				cur.append(cur[0])
	if cur.size() > 0:
		rings.append(cur)
	return rings

# --- top level -------------------------------------------------------------

## Parses a full .pbf tile buffer into { layer_name: { extent, features } }.
static func parse_tile(data: PackedByteArray) -> Dictionary:
	var tile := _parse_message(data)
	var result := {}
	if not tile.has(3):
		return result
	for layer_bytes in tile[3]:
		var layer := _parse_message(layer_bytes)
		var name: String = (layer[1][0] as PackedByteArray).get_string_from_utf8()
		var extent := 4096
		if layer.has(5):
			extent = layer[5][0]

		var keys: Array[String] = []
		if layer.has(3):
			for kb in layer[3]:
				keys.append((kb as PackedByteArray).get_string_from_utf8())

		var values: Array = []
		if layer.has(4):
			for vb in layer[4]:
				values.append(_parse_value(vb))

		var features := []
		if layer.has(2):
			for fb in layer[2]:
				var feat := _parse_message(fb)
				var gtype := 0
				if feat.has(3):
					gtype = feat[3][0]
				var tags: Array = []
				if feat.has(2):
					tags = _parse_packed_varints(feat[2][0])
				var props := {}
				var ti := 0
				while ti < tags.size() - 1:
					var kidx: int = tags[ti]
					var vidx: int = tags[ti + 1]
					if kidx < keys.size() and vidx < values.size():
						props[keys[kidx]] = values[vidx]
					ti += 2
				var cmds: Array = []
				if feat.has(4):
					cmds = _parse_packed_varints(feat[4][0])
				var rings := _decode_geometry(cmds)
				features.append({"type": gtype, "rings": rings, "props": props})

		result[name] = {"extent": extent, "features": features}
	return result
