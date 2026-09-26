#+build windows
package app

/*
    The microphone, on Windows: the waveIn part of winmm, the oldest and
    plainest way in. Every input device Windows knows (USB mics, a webcam's,
    an audio interface, a headset) is listed, and any of them can be opened.

    No callback: the device fills our buffers and marks each one done, and the
    frame collects the done ones (mic_os_read) and hands them straight back.
    A callback would run on another thread, in code a hot reload can unload
    under it; polling is always safe. The buffers live in App, so a reload
    does not move them while the device is writing.

    PITCH_RATE mono 16-bit. WAVE_MAPPED: Windows converts from whatever the
    device really runs at (usually 48 kHz).
*/

import "base:intrinsics"
import "core:unicode/utf16"
import win "core:sys/windows"
import "music"

foreign import winmm_in "system:Winmm.lib"

@(default_calling_convention = "system")
foreign winmm_in {
	waveInOpen :: proc(phwi: ^win.HWAVEIN, uDeviceID: win.UINT, pwfx: ^win.WAVEFORMATEX, dwCallback: win.DWORD_PTR, dwInstance: win.DWORD_PTR, fdwOpen: win.DWORD) -> win.MMRESULT ---
	waveInClose :: proc(hwi: win.HWAVEIN) -> win.MMRESULT ---
	waveInPrepareHeader :: proc(hwi: win.HWAVEIN, pwh: ^win.WAVEHDR, cbwh: win.UINT) -> win.MMRESULT ---
	waveInUnprepareHeader :: proc(hwi: win.HWAVEIN, pwh: ^win.WAVEHDR, cbwh: win.UINT) -> win.MMRESULT ---
	waveInAddBuffer :: proc(hwi: win.HWAVEIN, pwh: ^win.WAVEHDR, cbwh: win.UINT) -> win.MMRESULT ---
	waveInStart :: proc(hwi: win.HWAVEIN) -> win.MMRESULT ---
	waveInStop :: proc(hwi: win.HWAVEIN) -> win.MMRESULT ---
	waveInReset :: proc(hwi: win.HWAVEIN) -> win.MMRESULT ---
}

MIC_SUPPORTED :: true

Mic_Os :: struct {
	h:    win.HWAVEIN,
	hdr:  [MIC_BUFS]win.WAVEHDR,
	data: [MIC_BUFS][MIC_BUF]i16,
	next: int, // the buffer that comes back next
}

// Every input device, by name.
mic_os_list :: proc(out: []Mic_Device) -> int {
	n := min(int(win.waveInGetNumDevs()), len(out))
	for i in 0 ..< n {
		caps: win.WAVEINCAPSW
		out[i] = {}
		if win.waveInGetDevCapsW(win.UINT_PTR(i), &caps, size_of(caps)) != win.MMSYSERR_NOERROR do continue
		name := caps.szPname[:]
		for k in 0 ..< len(name) do if name[k] == 0 {name = name[:k]; break}
		out[i].len = utf16.decode_to_utf8(out[i].name[:], name)
	}
	return n
}

// Open device `device` (-1: whatever Windows has as the default) and start
// listening. "" on success, else what went wrong.
mic_os_open :: proc(m: ^Mic_Os, device: int) -> string {
	format := win.WAVEFORMATEX {
		wFormatTag      = win.WAVE_FORMAT_PCM,
		nChannels       = 1,
		nSamplesPerSec  = music.PITCH_RATE,
		nAvgBytesPerSec = music.PITCH_RATE * 2,
		nBlockAlign     = 2,
		wBitsPerSample  = 16,
	}
	id := device < 0 ? win.WAVE_MAPPER : win.UINT(device)
	flags := win.DWORD(win.CALLBACK_NULL)
	if device >= 0 do flags |= win.WAVE_MAPPED
	m^ = {}
	if r := waveInOpen(&m.h, id, &format, 0, 0, flags); r != win.MMSYSERR_NOERROR {
		m.h = nil
		return r == 32 ? "that device cannot record at this format" : (r == 4 ? "the device is in use by another program" : "could not open the device")
	}
	for i in 0 ..< MIC_BUFS {
		h := &m.hdr[i]
		h.lpData = win.LPSTR(&m.data[i][0])
		h.dwBufferLength = MIC_BUF * 2
		waveInPrepareHeader(m.h, h, size_of(win.WAVEHDR))
		waveInAddBuffer(m.h, h, size_of(win.WAVEHDR))
	}
	if waveInStart(m.h) != win.MMSYSERR_NOERROR {
		mic_os_close(m)
		return "the device would not start"
	}
	return ""
}

mic_os_close :: proc(m: ^Mic_Os) {
	if m.h == nil do return
	waveInStop(m.h)
	waveInReset(m.h) // hands every buffer back
	for i in 0 ..< MIC_BUFS do waveInUnprepareHeader(m.h, &m.hdr[i], size_of(win.WAVEHDR))
	waveInClose(m.h)
	m.h = nil
}

// Everything recorded since the last call, oldest first, as -1..1, into
// `out`; returns how many samples. The buffers go straight back to the
// device.
mic_os_read :: proc(m: ^Mic_Os, out: []f32) -> int {
	if m.h == nil do return 0
	n := 0
	for _ in 0 ..< MIC_BUFS {
		h := &m.hdr[m.next]
		// The device writes this from its own thread: read it fresh.
		if intrinsics.volatile_load(&h.dwFlags) & win.WHDR_DONE == 0 do break
		got := min(int(h.dwBytesRecorded) / 2, MIC_BUF, len(out) - n)
		for k in 0 ..< got do out[n + k] = f32(m.data[m.next][k]) / 32768
		n += got
		h.dwFlags &~= win.WHDR_DONE
		h.dwBytesRecorded = 0
		waveInAddBuffer(m.h, h, size_of(win.WAVEHDR))
		m.next = (m.next + 1) % MIC_BUFS
	}
	return n
}
