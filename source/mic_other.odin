#+build !windows
package app

/*
    The microphone everywhere but Windows: not in this build yet. Input mode
    says so instead of listening. (mic_windows.odin is the real thing; a
    Linux or macOS version would fill in these four procedures.)
*/

MIC_SUPPORTED :: false

Mic_Os :: struct {}

mic_os_list :: proc(out: []Mic_Device) -> int {return 0}

mic_os_open :: proc(m: ^Mic_Os, device: int) -> string {
	return "microphone input is Windows-only in this build"
}

mic_os_close :: proc(m: ^Mic_Os) {}

mic_os_read :: proc(m: ^Mic_Os, out: []f32) -> int {return 0}
