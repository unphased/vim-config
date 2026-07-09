local M = {}

local function non_empty(path)
	local status = Command("test"):arg({ "-s", path }):status()
	return status and status.success
end

local function extract_preview(src, out)
	local script = [[
if command -v exiftool >/dev/null 2>&1; then
	exiftool -b -PreviewImage "$1" > "$2" 2>/dev/null && test -s "$2" && exit 0
fi
if test -r /opt/homebrew/bin/exiftool; then
	perl /opt/homebrew/bin/exiftool -b -PreviewImage "$1" > "$2" 2>/dev/null && test -s "$2" && exit 0
fi
exit 1
]]

	local status = Command("sh"):arg({ "-c", script, "raw-thumb", src, out }):status()
	return status and status.success and non_empty(out)
end

local function render_with_sips(src, out)
	local size = tostring(math.max(rt.preview.max_width, rt.preview.max_height))
	local status = Command("sips")
		:arg({ "-Z", size, "-s", "format", "jpeg", src, "--out", out })
		:status()

	return status and status.success and non_empty(out)
end

function M:peek(job)
	local start, cache = os.clock(), ya.file_cache(job)
	if not cache then
		return
	end

	local ok, err = self:preload(job)
	if not ok or err then
		return ya.preview_widget(job, err)
	end

	ya.sleep(math.max(0, rt.preview.image_delay / 1000 + start - os.clock()))
	local _, show_err = ya.image_show(cache, job.area)
	ya.preview_widget(job, show_err)
end

function M:seek() end

function M:preload(job)
	local cache = ya.file_cache(job)
	if not cache or fs.cha(cache) then
		return true
	end

	local src = tostring(job.file.path)
	local jpg = tostring(cache) .. ".jpg"

	if extract_preview(src, jpg) or render_with_sips(src, jpg) then
		return ya.image_precache(Url(jpg), cache)
	end

	return require("magick"):preload(job)
end

function M:spot(job)
	require("file"):spot(job)
end

return M
