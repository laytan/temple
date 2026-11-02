package temple_cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// Intentional distinction from `is_watched_workspace_file`: `--warn-unused` only checks
// explicit template suffixes (`.temple.twig`, `.temple.html`, `.twig`) and ignores plain
// `.html` files so static HTML assets in the repository are not flagged as orphan templates.
is_template_candidate_file :: proc(path: string) -> bool {
	return strings.has_suffix(path, ".temple.twig") ||
		strings.has_suffix(path, ".temple.html") ||
		strings.has_suffix(path, ".twig")
}

filter_unused_templates :: proc(
	candidate_files: []string,
	used_files: map[string]bool,
	allocator := context.allocator,
) -> [dynamic]string {
	unused := make([dynamic]string, 0, len(candidate_files), allocator)
	for f in candidate_files {
		if !is_template_candidate_file(f) {
			continue
		}
		if !used_files[f] {
			append(&unused, strings.clone(f, allocator))
		}
	}
	slice.sort(unused[:])
	return unused
}

discover_project_template_files :: proc(root_dir: string, allocator := context.allocator) -> [dynamic]string {
	Discover_State :: struct {
		files:     ^[dynamic]string,
		allocator: mem.Allocator,
	}
	files := make([dynamic]string, allocator)
	state := Discover_State{files = &files, allocator = allocator}

	walk_project_tree(root_dir, &state, proc(info: os.File_Info, user_data: rawptr) {
		s := cast(^Discover_State)user_data
		if info.type == .Directory || !is_template_candidate_file(info.name) {
			return
		}
		if ap, err := os.get_absolute_path(info.fullpath, s.allocator); err == nil {
			append(s.files, ap)
		} else {
			append(s.files, strings.clone(info.fullpath, s.allocator))
		}
	})

	slice.sort(files[:])
	return files
}

File_Stamp :: struct {
	mtime_nsec: i64,
	size:       i64,
}

Workspace_Snapshot :: map[string]File_Stamp

is_watched_workspace_file :: proc(name: string) -> bool {
	return strings.has_suffix(name, ".odin") ||
		strings.has_suffix(name, ".temple.twig") ||
		strings.has_suffix(name, ".temple.html") ||
		strings.has_suffix(name, ".twig") ||
		strings.has_suffix(name, ".html")
}

capture_workspace_snapshot :: proc(
	root_dir: string,
	exclude_out_file := "",
	allocator := context.allocator,
	extra_files: []string = nil,
) -> Workspace_Snapshot {
	snap := make(Workspace_Snapshot, allocator)
	abs_exclude := ""
	if len(exclude_out_file) > 0 {
		if ap, err := os.get_absolute_path(exclude_out_file, context.temp_allocator); err == nil {
			abs_exclude = ap
		} else {
			abs_exclude = exclude_out_file
		}
	}

	Snapshot_Walk_State :: struct {
		abs_exclude: string,
		snap:        ^Workspace_Snapshot,
		allocator:   mem.Allocator,
	}
	state := Snapshot_Walk_State{
		abs_exclude = abs_exclude,
		snap        = &snap,
		allocator   = allocator,
	}

	snapshot_visit :: proc(info: os.File_Info, user_data: rawptr) {
		s := cast(^Snapshot_Walk_State)user_data
		if info.type == .Directory || !is_watched_workspace_file(info.name) || info.name == "templates.odin" {
			return
		}
		abs_path := info.fullpath
		if ap, err := os.get_absolute_path(info.fullpath, context.temp_allocator); err == nil {
			abs_path = ap
		}
		if len(s.abs_exclude) > 0 && abs_path == s.abs_exclude {
			return
		}
		if _, exists := s.snap^[abs_path]; !exists {
			s.snap^[strings.clone(abs_path, s.allocator)] = File_Stamp{
				mtime_nsec = info.modification_time._nsec,
				size       = info.size,
			}
		}
	}

	walk_project_tree(root_dir, &state, snapshot_visit)

	for extra in extra_files {
		if len(extra) == 0 {
			continue
		}
		abs_extra := extra
		if ap, err := os.get_absolute_path(extra, context.temp_allocator); err == nil {
			abs_extra = ap
		}
		if len(abs_exclude) > 0 && abs_extra == abs_exclude {
			continue
		}
		if info, stat_err := os.stat(abs_extra, context.temp_allocator); stat_err == nil {
			if info.type == .Directory {
				walk_project_tree(abs_extra, &state, snapshot_visit)
			} else if _, exists := snap[abs_extra]; !exists {
				snap[strings.clone(abs_extra, allocator)] = File_Stamp{
					mtime_nsec = info.modification_time._nsec,
					size       = info.size,
				}
			}
		}
	}

	return snap
}

has_workspace_snapshot_changed :: proc(prev, curr: Workspace_Snapshot) -> bool {
	if len(prev) != len(curr) {
		return true
	}
	for k, curr_val in curr {
		prev_val, found := prev[k]
		if !found || prev_val != curr_val {
			return true
		}
	}
	return false
}

watch_workspace :: proc(opts: Cli_Options, max_iterations := 0, poll_interval := 250 * time.Millisecond) {
	fmt.printf("watching %q for template and Odin file changes...\n", opts.project_dir)

	snapshot_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&snapshot_arena)
	defer mem.dynamic_arena_destroy(&snapshot_arena)
	snap_alloc := mem.dynamic_arena_allocator(&snapshot_arena)

	watched_used := make([dynamic]string, snap_alloc)
	_ = run_cli_once(opts, &watched_used)

	prev_snap := capture_workspace_snapshot(opts.project_dir, opts.out_file, snap_alloc, watched_used[:])
	free_all(context.temp_allocator)

	for iter := 0; max_iterations <= 0 || iter < max_iterations; iter += 1 {
		time.sleep(poll_interval)

		curr_snap := capture_workspace_snapshot(opts.project_dir, opts.out_file, context.temp_allocator, watched_used[:])
		if has_workspace_snapshot_changed(prev_snap, curr_snap) {
			fmt.println("change detected; recompiling templates...")
			mem.dynamic_arena_reset(&snapshot_arena)
			watched_used = make([dynamic]string, snap_alloc)
			_ = run_cli_once(opts, &watched_used)
			prev_snap = capture_workspace_snapshot(opts.project_dir, opts.out_file, snap_alloc, watched_used[:])
		}
		free_all(context.temp_allocator)
	}
}
