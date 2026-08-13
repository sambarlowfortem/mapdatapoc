## Shared on-disk tile cache used by TerrainRGBLoader, MVTTileRenderer, and
## SatelliteTileLoader - every tile fetched over HTTP gets written here on
## first fetch and read from here on every fetch after, cutting repeat load
## times and external API/tile-server traffic to near zero for areas
## already visited.
##
## Lives in the user's OS Documents folder (OS.get_system_dir(...DOCUMENTS))
## under CACHE_FOLDER_NAME, rather than somewhere inside the project or a
## hidden app-data directory, specifically so it's somewhere the user will
## actually find it - to inspect it, clear it by hand, or notice it eating
## disk space - rather than a location they'd have to go hunting for.
## enforce_size_cap() (called once at startup, see main.gd) evicts the
## least-recently-modified files first once the cache exceeds
## MAX_CACHE_SIZE_MB, so normal use can't grow it without bound.
extends RefCounted
class_name TileCache

const CACHE_FOLDER_NAME := "skydome_sim_map_cache"
const MAX_CACHE_SIZE_MB := 2048


## Absolute path to the cache root, creating it if missing.
static func root_dir() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var path := docs.path_join(CACHE_FOLDER_NAME)
	DirAccess.make_dir_recursive_absolute(path)
	return path


## Full cache file path for one tile from `template` (a {z}/{x}/{y} URL
## template, exactly as passed to TileSource.url_for elsewhere) at (z,x,y).
## Tiles from different templates never share a path, even at the same
## z/x/y, since the folder name is derived from the template itself - see
## _slug_for_template().
static func path_for(template: String, z: int, x: int, y: int) -> String:
	var slug := _slug_for_template(template)
	var ext := _extension_for_template(template)
	return root_dir().path_join(slug).path_join(str(z)).path_join(str(x)).path_join("%d.%s" % [y, ext])


## Reads `path` if it exists, returning its bytes - or an empty array if
## it's not cached yet.
static func read(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	return f.get_buffer(f.get_length())


## Writes `data` to `path`, creating any missing parent directories first.
static func write(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("TileCache: could not write %s" % path)
		return
	f.store_buffer(data)


## Derives a filesystem-safe, human-readable folder name from `template`'s
## scheme+host+path up to (but not including) the {z}/{x}/{y} pattern itself
## - e.g. "https://api.maptiler.com/tiles/v3/{z}/{x}/{y}.pbf?key=..." ->
## "api.maptiler.com_tiles_v3". Any query string (API keys, etc.) is
## dropped first since it's not part of a tile's identity.
static func _slug_for_template(template: String) -> String:
	var no_query := template.get_slice("?", 0)
	var base := no_query.split("{z}")[0]
	base = base.replace("https://", "").replace("http://", "")
	base = base.replace("/", "_").replace(":", "_")
	while base.ends_with("_"):
		base = base.substr(0, base.length() - 1)
	return base


## File extension for tiles from `template` - e.g. "pbf", "jpg", "webp" -
## read straight off the template's own {y}.<ext> suffix.
static func _extension_for_template(template: String) -> String:
	return template.get_slice("?", 0).get_extension()


## Walks the whole cache, and if it's over MAX_CACHE_SIZE_MB, deletes the
## least-recently-modified files first until it's back under the cap. Meant
## to be called once at startup (see main.gd) rather than after every
## individual tile write, since it has to walk the entire cache tree.
static func enforce_size_cap() -> void:
	var root := root_dir()
	var files := []  # [{path, size, modified_time}]
	_collect_files(root, files)
	var total := 0
	for f in files:
		total += f["size"]
	var cap_bytes := MAX_CACHE_SIZE_MB * 1024 * 1024
	if total <= cap_bytes:
		return
	files.sort_custom(func(a, b): return a["modified_time"] < b["modified_time"])
	var evicted := 0
	var i := 0
	while total > cap_bytes and i < files.size():
		DirAccess.remove_absolute(files[i]["path"])
		total -= files[i]["size"]
		evicted += 1
		i += 1
	print("TileCache: evicted %d file(s) to stay under %d MB" % [evicted, MAX_CACHE_SIZE_MB])


static func _collect_files(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var full := dir_path.path_join(name)
			if dir.current_is_dir():
				_collect_files(full, out)
			else:
				out.append({"path": full, "size": _file_size(full), "modified_time": FileAccess.get_modified_time(full)})
		name = dir.get_next()
	dir.list_dir_end()


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size
