#!/usr/bin/env bash

line='........................................'
have_ucode=0
ucode=""

if command -v ucode >/dev/null 2>&1; then
	have_ucode=1

	# Create patched copies of the library modules that convert ES module imports of
	# fs/uci to require() calls, so the mock framework can intercept them through the
	# module cache. Each `import { a, b } from 'fs';` becomes
	# `let _fs = require('fs'), a = _fs.a, b = _fs.b;`.
	patch_dir="/tmp/mwan4_test_modules.$$"
	mkdir -p "$patch_dir"

	for module in mwan4 packages dnsmasq pbr_import connections stability flush continuity; do
		awk '
			/^import \{ .* \} from .(fs|uci).;$/ {
				mod = $0; sub(/.*from \x27/, "", mod); sub(/\x27;.*/, "", mod)
				names = $0; sub(/^import \{ /, "", names); sub(/ \} from.*/, "", names)
				n = split(names, a, /, */)
				out = "let _" mod " = require(\x27" mod "\x27)"
				for (i = 1; i <= n; i++) out = out ", " a[i] " = _" mod "." a[i]
				print out ";"
				next
			}
			{ print }
		' "./files/lib/mwan4/$module.uc" > "$patch_dir/$module.uc"
	done

	sed -e "s|'/lib/mwan4/\([a-z0-9_]*\)\.uc'|'\1'|" \
		./files/usr/share/rpcd/ucode/mwan4 > "$patch_dir/rpcd_mwan4.uc"

	trap "rm -rf '$patch_dir'" EXIT

	# Search paths: patched mwan4.uc first, then tests/lib (for mocklib), then original source
	ucode="ucode -S -L$patch_dir -L./tests/lib -L./files/lib/mwan4"
fi

extract_sections() {
	local file=$1
	local dir=$2
	local count=0
	local tag line outfile

	while IFS= read -r line; do
		case "$line" in
			"-- Testcase --")
				tag="test"
				count=$((count + 1))
				outfile=$(printf "%s/%03d.in" "$dir" $count)
				printf "" > "$outfile"
			;;
			"-- Environment --")
				tag="env"
				count=$((count + 1))
				outfile=$(printf "%s/%03d.env" "$dir" $count)
				printf "" > "$outfile"
			;;
			"-- Expect stdout --"|"-- Expect stderr --"|"-- Expect exitcode --")
				tag="${line#-- Expect }"
				tag="${tag% --}"
				count=$((count + 1))
				outfile=$(printf "%s/%03d.%s" "$dir" $count "$tag")
				printf "" > "$outfile"
			;;
			"-- File "*" --")
				tag="file"
				outfile="${line#-- File }"
				outfile="$(echo "${outfile% --}" | xargs)"
				outfile="$dir/files$(readlink -m "/${outfile:-file}")"
				mkdir -p "$(dirname "$outfile")"
				printf "" > "$outfile"
			;;
			"-- End --")
				tag=""
				outfile=""
			;;
			*)
				if [ -n "$tag" ]; then
					printf "%s\\n" "$line" >> "$outfile"
				fi
			;;
		esac
	done < "$file"

	return $(ls -l "$dir/"*.in 2>/dev/null | wc -l)
}

run_testcase() {
	local num=$1
	local dir=$2
	local in=$3
	local env=$4
	local out=$5
	local err=$6
	local code=$7
	local fail=0

	$ucode \
		-D MOCK_SEARCH_PATH='["'"$dir"'/files", "./tests/mocks"]' \
		${env:+-F "$env"} \
		-l mocklib \
		- <"$in" >"$dir/res.out" 2>"$dir/res.err"

	printf "%d\n" $? > "$dir/res.code"

	touch "$dir/empty"

	if ! cmp -s "$dir/res.err" "${err:-$dir/empty}"; then
		[ $fail = 0 ] && printf "!\n"
		printf "Testcase #%d: Expected stderr did not match:\n" $num
		diff -u --color=always --label="Expected stderr" --label="Resulting stderr" "${err:-$dir/empty}" "$dir/res.err"
		printf -- "---\n"
		fail=1
	fi

	if ! cmp -s "$dir/res.out" "${out:-$dir/empty}"; then
		[ $fail = 0 ] && printf "!\n"
		printf "Testcase #%d: Expected stdout did not match:\n" $num
		diff -u --color=always --label="Expected stdout" --label="Resulting stdout" "${out:-$dir/empty}" "$dir/res.out"
		printf -- "---\n"
		fail=1
	fi

	if [ -n "$code" ] && ! cmp -s "$dir/res.code" "$code"; then
		[ $fail = 0 ] && printf "!\n"
		printf "Testcase #%d: Expected exit code did not match:\n" $num
		diff -u --color=always --label="Expected code" --label="Resulting code" "$code" "$dir/res.code"
		printf -- "---\n"
		fail=1
	fi

	return $fail
}

run_test() {
	local file=$1
	local name=${file##*/}
	local res ecode eout eerr ein eenv tests
	local testcase_first=0 failed=0 count=0

	printf "%s %s " "$name" "${line:${#name}}"

	mkdir "/tmp/test.$$"

	extract_sections "$file" "/tmp/test.$$"
	tests=$?

	[ -f "/tmp/test.$$/001.in" ] && testcase_first=1

	for res in "/tmp/test.$$/"[0-9]*; do
		case "$res" in
			*.in)
				count=$((count + 1))

				if [ $testcase_first = 1 ]; then
					# Flush previous test
					if [ -n "$ein" ]; then
						run_testcase $count "/tmp/test.$$" "$ein" "$eenv" "$eout" "$eerr" "$ecode" || failed=$((failed + 1))

						eout=""
						eerr=""
						ecode=""
						eenv=""
					fi

					ein=$res
				else
					run_testcase $count "/tmp/test.$$" "$res" "$eenv" "$eout" "$eerr" "$ecode" || failed=$((failed + 1))

					eout=""
					eerr=""
					ecode=""
					eenv=""
				fi

			;;
			*.env) eenv=$res ;;
			*.stdout) eout=$res ;;
			*.stderr) eerr=$res ;;
			*.exitcode) ecode=$res ;;
		esac
	done

	# Flush last test
	if [ $testcase_first = 1 ] && [ -n "$eout$eerr$ecode" ]; then
		run_testcase $count "/tmp/test.$$" "$ein" "$eenv" "$eout" "$eerr" "$ecode" || failed=$((failed + 1))
	fi

	rm -r "/tmp/test.$$"

	if [ $failed = 0 ]; then
		printf "OK\n"
	else
		printf "%s %s FAILED (%d/%d)\n" "$name" "${line:${#name}}" $failed $tests
	fi

	return $failed
}


n_tests=0
n_fails=0

select_tests="$@"

use_test() {
	local input="$(readlink -f "$1")"
	local test

	[ -f "$input" ] || return 1
	[ -n "$select_tests" ] || return 0

	for test in "$select_tests"; do
		test="$(readlink -f "$test")"

		[ "$test" != "$input" ] || return 0
	done

	return 1
}

if [ "$have_ucode" = 1 ]; then
	for catdir in tests/[0-9][0-9]_*; do
		[ -d "$catdir" ] || continue

		printf "\n##\n## Running %s tests\n##\n\n" "${catdir##*/[0-9][0-9]_}"

		for testfile in "$catdir/"[0-9][0-9]_*; do
			use_test "$testfile" || continue

			n_tests=$((n_tests + 1))
			run_test "$testfile" || n_fails=$((n_fails + 1))
		done
	done
else
	printf "\n##\n## Skipping ucode tests (ucode not found)\n##\n\n"
fi

# ── Shell script syntax checks ──────────────────────────────────────

printf "\n##\n## Checking shell script syntax\n##\n\n"
for shellscript in \
	files/etc/init.d/* \
	files/etc/uci-defaults/*; do
	[ -f "$shellscript" ] || continue
	head -1 "$shellscript" | grep -q '^#!/bin/sh' || continue
	name="${shellscript#files/}"
	n_tests=$((n_tests + 1))
	printf "%s %s " "$name" "${line:${#name}}"
	if sh -n "$shellscript" 2>/dev/null; then
		printf "OK\n"
	else
		printf "FAIL\n"
		sh -n "$shellscript"
		n_fails=$((n_fails + 1))
	fi
done

printf "\nRan %d tests, %d okay, %d failures\n" $n_tests $((n_tests - n_fails)) $n_fails
exit $n_fails
