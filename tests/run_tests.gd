extends SceneTree

const LEVELS := [0x0000, 0x0013, 0x0017, 0x0035, 0x1970, 0x2979, 0x9999]
const STAGES := [
	"random",
	"smooth0",
	"smooth1",
	"smooth2",
	"smooth3",
	"scaled",
	"despike0",
	"despike1",
	"despike2",
	"despike3",
	"shape",
	"swap",
]
const EXPECTED_CPC_CODES := {
	"41954266": 0x0000,
	"82497760": 0x0013,
	"18167694": 0x0017,
	"46855644": 0x0035,
	"96864996": 0x1970,
	"55952892": 0x2979,
	"77886682": 0x9999,
}

var _generator: Node
var _failures: Array[String] = []

func _initialize() -> void:
	_generator = load("res://scripts/landscape_generator.gd").new() as Node
	_run()

func _run() -> void:
	_test_cpc_code_lookup()
	_test_golden_landscape_stages()

	if _failures.is_empty():
		_write_result("PASS\n")
		print("All Sentinel generator tests passed.")
		quit(0)
		return

	var lines: Array[String] = ["FAIL"]
	for failure in _failures:
		push_error(failure)
		lines.append(failure)
	_write_result("\n".join(lines) + "\n")
	print("Sentinel generator tests failed: %d failure(s)." % _failures.size())
	quit(1)

func _test_cpc_code_lookup() -> void:
	for code in EXPECTED_CPC_CODES.keys():
		var expected_level: int = EXPECTED_CPC_CODES[code]
		var actual_level: int = int(_generator.call("cpc_code_to_landscape_bcd", code))
		_assert_equal(actual_level, expected_level, "CPC code %s should decode to %04X" % [code, expected_level])

		var by_code: Dictionary = _generator.call("generate_level_snapshot", actual_level) as Dictionary
		var by_level: Dictionary = _generator.call("generate_level_snapshot", expected_level) as Dictionary
		_assert_bytes_equal(
			_generator.call("map_to_memory_bytes", by_code["map"]) as PackedByteArray,
			_generator.call("map_to_memory_bytes", by_level["map"]) as PackedByteArray,
			"CPC code %s should generate the same level data as %04X" % [code, expected_level]
		)

func _test_golden_landscape_stages() -> void:
	for level in LEVELS:
		var snapshot: Dictionary = _generator.call("generate_level_snapshot", level) as Dictionary
		var stages: Dictionary = snapshot["stages"]

		for stage_name in STAGES:
			var actual: PackedByteArray = _generator.call("map_to_memory_bytes", stages[stage_name]) as PackedByteArray
			var golden_path := "res://example_code/golden/%04X_%s.bin" % [level, stage_name]
			var expected: PackedByteArray = FileAccess.get_file_as_bytes(golden_path)
			_assert_bytes_equal(actual, expected, "%04X %s should match golden output" % [level, stage_name])

		var expected_iterations := _read_iteration_count(level)
		_assert_equal(
			int(snapshot["rng_usage"]),
			expected_iterations,
			"%04X RNG usage should match golden iteration count" % level
		)

func _write_result(text: String) -> void:
	var file := FileAccess.open("res://tests/latest_test_run.txt", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)

func _read_iteration_count(level: int) -> int:
	var bytes := FileAccess.get_file_as_bytes("res://example_code/golden/iterations.bin")
	var offset := level * 2
	if offset + 1 >= bytes.size():
		return -1
	var value := int(bytes[offset]) | (int(bytes[offset + 1]) << 8)
	if value >= 0x8000:
		value -= 0x10000
	return value

func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual == expected:
		return
	_failures.append("%s (expected=%s actual=%s)" % [message, str(expected), str(actual)])

func _assert_bytes_equal(actual: PackedByteArray, expected: PackedByteArray, message: String) -> void:
	if actual == expected:
		return
	var mismatch_index := -1
	var limit := mini(actual.size(), expected.size())
	for i in range(limit):
		if actual[i] != expected[i]:
			mismatch_index = i
			break
	if mismatch_index == -1 and actual.size() != expected.size():
		mismatch_index = limit
	_failures.append(
		"%s (actual_size=%d expected_size=%d first_mismatch=%d)" %
		[message, actual.size(), expected.size(), mismatch_index]
	)
