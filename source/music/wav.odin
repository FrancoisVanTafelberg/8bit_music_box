package music

import "core:os"

// Write stereo interleaved f32 samples as a 16-bit PCM WAV: the most widely
// readable audio file there is, and what ffmpeg is handed for everything else.
write_wav :: proc(path: string, samples: []f32, rate: int = SAMPLE_RATE, channels: int = 2) -> bool {
	n := len(samples)
	data_bytes := n * 2
	buf := make([]u8, 44 + data_bytes)
	defer delete(buf)

	put_u32 :: proc(b: []u8, at: int, v: u32) {
		b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
	put_u16 :: proc(b: []u8, at: int, v: u16) {
		b[at], b[at + 1] = u8(v), u8(v >> 8)
	}
	copy(buf[0:], "RIFF")
	put_u32(buf, 4, u32(36 + data_bytes))
	copy(buf[8:], "WAVEfmt ")
	put_u32(buf, 16, 16) // fmt chunk size
	put_u16(buf, 20, 1) // PCM
	put_u16(buf, 22, u16(channels))
	put_u32(buf, 24, u32(rate))
	put_u32(buf, 28, u32(rate * channels * 2))
	put_u16(buf, 32, u16(channels * 2))
	put_u16(buf, 34, 16)
	copy(buf[36:], "data")
	put_u32(buf, 40, u32(data_bytes))
	for s, i in samples {
		v := i16(clamp(s, -1, 1) * 32767)
		put_u16(buf, 44 + i * 2, u16(v))
	}
	return os.write_entire_file(path, buf) == nil
}
