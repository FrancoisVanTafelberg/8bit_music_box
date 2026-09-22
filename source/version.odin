package app

// core:os was rebuilt on os2 during 2025-2026 and this app uses the new shape
// (read_directory_by_path, read_entire_file_from_path, process_exec). An older
// compiler fails with a page of errors about missing os symbols; this says so
// in one line instead.
when ODIN_VERSION < "dev-2026-06" {
	#panic("8-Bit Music Box needs Odin dev-2026-06 or newer, and this compiler is " + ODIN_VERSION + ".")
}
