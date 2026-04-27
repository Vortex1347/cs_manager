# Suggested Commands
- Parse / smoke startup: `godot --headless --path /Users/ataiyrysbekov/Documents/GitHub/cs_manager --quit`
- Short runtime smoke: `python3 - <<'PY'\nimport subprocess\ncmd=['godot','--headless','--path','/Users/ataiyrysbekov/Documents/GitHub/cs_manager']\ntry:\n    out=subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=22)\n    print(out.stdout)\nexcept subprocess.TimeoutExpired as e:\n    print((e.stdout or '')[-12000:])\nPY`
- Extended live smoke: `sh -lc 'godot --headless --path /Users/ataiyrysbekov/Documents/GitHub/cs_manager > /tmp/cs_manager.log 2>&1 & pid=$!; sleep 22; kill $pid >/dev/null 2>&1 || true; wait $pid >/dev/null 2>&1 || true; cat /tmp/cs_manager.log'`
- Tactical-map sanity grep: `rg -n "default_a_long|b_exec|mid_to_b_split|ct_long_contest|plant_slot|retake_lane|bomb_cover_package" /Users/ataiyrysbekov/Documents/GitHub/cs_manager/scripts`
- Fast text search: `rg -n "pattern" /Users/ataiyrysbekov/Documents/GitHub/cs_manager`
- Inspect scene/script slices: `sed -n 'start,endp' /Users/ataiyrysbekov/Documents/GitHub/cs_manager/<path>`
- Git status: `git status --short`
