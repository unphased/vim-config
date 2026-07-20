local M = {}

local function non_empty(path)
	local status = Command("test"):arg({ "-s", path }):status()
	return status and status.success
end

local function extract_sony_preview(src, out)
	local script = [[
use strict;
use warnings;

my ($src, $out) = @ARGV;
open my $fh, "<:raw", $src or exit 1;
read($fh, my $header, 8) == 8 or exit 1;

my $le;
if (substr($header, 0, 2) eq "II") {
	$le = 1;
} elsif (substr($header, 0, 2) eq "MM") {
	$le = 0;
} else {
	exit 1;
}

sub u16 {
	my ($bytes, $le) = @_;
	return unpack($le ? "v" : "n", $bytes);
}

sub u32 {
	my ($bytes, $le) = @_;
	return unpack($le ? "V" : "N", $bytes);
}

u16(substr($header, 2, 2), $le) == 42 or exit 1;
my $ifd = u32(substr($header, 4, 4), $le);
seek($fh, $ifd, 0) or exit 1;
read($fh, my $count_bytes, 2) == 2 or exit 1;

my $count = u16($count_bytes, $le);
my ($start, $length);
for (1 .. $count) {
	read($fh, my $entry, 12) == 12 or exit 1;
	my $tag = u16(substr($entry, 0, 2), $le);
	my $type = u16(substr($entry, 2, 2), $le);
	my $n = u32(substr($entry, 4, 4), $le);
	next unless $type == 4 && $n == 1;

	my $value = u32(substr($entry, 8, 4), $le);
	$start = $value if $tag == 0x0201;
	$length = $value if $tag == 0x0202;
}

exit 1 unless defined $start && defined $length && $length > 2;
seek($fh, $start, 0) or exit 1;
read($fh, my $jpeg, $length) == $length or exit 1;
exit 1 unless substr($jpeg, 0, 2) eq "\xff\xd8";

open my $oh, ">:raw", $out or exit 1;
print {$oh} $jpeg or exit 1;
]]

	local status = Command("perl"):arg({ "-e", script, src, out }):status()
	return status and status.success and non_empty(out)
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

	if extract_sony_preview(src, jpg) or extract_preview(src, jpg) then
		return ya.image_precache(Url(jpg), cache)
	end

	local complete, err = require("magick"):preload(job)
	if complete and not err then
		return complete, err
	end

	if render_with_sips(src, jpg) then
		return ya.image_precache(Url(jpg), cache)
	end

	return complete, err
end

function M:spot(job)
	require("file"):spot(job)
end

return M
