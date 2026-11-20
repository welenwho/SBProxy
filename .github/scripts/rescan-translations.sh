#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"
REPO_ROOT="$CI_REPO_ROOT"
# Keep the scanner/update pair reproducible.  Fetching from LuCI's moving
# master branch made a scheduled run able to change the extraction behavior
# without a corresponding change in this repository.
LUCI_I18N_COMMIT="${LUCI_I18N_COMMIT:-19365a7fd32bb223a3a347594496d35df2670154}"
LUCI_I18N_DIR="${LUCI_I18N_DIR:-}"
TEMP_DIR=""
SCANNER_DIR=""
POT_TEMP=""

cleanup() {
	[[ -z "$POT_TEMP" ]] || rm -f -- "$POT_TEMP"
	[[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
	[[ -z "$SCANNER_DIR" ]] || rm -rf -- "$SCANNER_DIR"
}
trap cleanup EXIT INT TERM

if [[ -n "$LUCI_I18N_DIR" ]]; then
	SCAN_SCRIPT="$LUCI_I18N_DIR/i18n-scan.pl"
	UPDATE_SCRIPT="$LUCI_I18N_DIR/i18n-update.pl"
else
	TEMP_DIR="$(mktemp -d)"
	SCAN_SCRIPT="$TEMP_DIR/i18n-scan.pl"
	UPDATE_SCRIPT="$TEMP_DIR/i18n-update.pl"
	curl -fsSL --retry 3 \
		-o "$SCAN_SCRIPT" \
		"https://raw.githubusercontent.com/openwrt/luci/$LUCI_I18N_COMMIT/build/i18n-scan.pl"
	curl -fsSL --retry 3 \
		-o "$UPDATE_SCRIPT" \
		"https://raw.githubusercontent.com/openwrt/luci/$LUCI_I18N_COMMIT/build/i18n-update.pl"
fi

[[ -f "$SCAN_SCRIPT" ]] || {
	echo "Missing official i18n-scan.pl: $SCAN_SCRIPT" >&2
	exit 1
}
[[ -f "$UPDATE_SCRIPT" ]] || {
	echo "Missing official i18n-update.pl: $UPDATE_SCRIPT" >&2
	exit 1
}

# Return 0 only when every msgid removed from the previous template is absent
# from translation calls in the scanned source roots.  A string still wrapped
# in _(), translate(), N_(), or ntranslate() is an extraction failure, including
# hand-written entries that have no source location.
translation_drop_is_obsolete() {
	local previous="$1"
	local scanned="$2"
	shift 2

	python3 - "$previous" "$scanned" "$@" <<'PY'
import pathlib, re, sys

CALL_RE = re.compile(
    r'''(?:_\(|\btranslate(?:f)?\(|\bN_\(|\bntranslate\()\s*(['"])(.*?)(?<!\\)\1''',
    re.S,
)

def js_unescape(value):
    output = []
    index = 0
    while index < len(value):
        if value[index] == '\\' and index + 1 < len(value):
            escaped = value[index + 1]
            output.append({
                'n': '\n', 't': '\t', 'r': '\r', '"': '"', "'": "'", '\\': '\\',
            }.get(escaped, escaped))
            index += 2
        else:
            output.append(value[index])
            index += 1
    return ''.join(output)

def po_unescape(value):
    output = []
    index = 0
    while index < len(value):
        if value[index] == '\\' and index + 1 < len(value):
            escaped = value[index + 1]
            output.append({
                'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\',
            }.get(escaped, '\\' + escaped))
            index += 2
        else:
            output.append(value[index])
            index += 1
    return ''.join(output)

def strip_obsolete(line):
    if line.startswith('#~'):
        line = line[2:]
        if line.startswith(' '):
            line = line[1:]
    return line

def parse_messages(path):
    text = pathlib.Path(path).read_text(encoding='utf-8')
    messages = {}
    for block in re.split(r'\n\n+', text.strip() + '\n'):
        lines = [strip_obsolete(line) for line in block.splitlines()]
        block = '\n'.join(lines)
        if not re.search(r'^msgid "', block, re.M):
            continue
        parts = []
        in_msgid = False
        for line in lines:
            if line.startswith('msgid "'):
                in_msgid = True
                parts = [line[len('msgid "'):-1]]
            elif line.startswith('msgid_plural ') or line.startswith('msgstr'):
                in_msgid = False
            elif in_msgid and line.startswith('"') and line.endswith('"'):
                parts.append(line[1:-1])
        msgid = po_unescape(''.join(parts))
        if msgid:
            messages[msgid] = True
    return messages

def quoted_calls(source_roots):
    calls = set()
    for root in source_roots:
        root_path = pathlib.Path(root)
        if not root_path.is_dir():
            continue
        for path in root_path.rglob('*'):
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding='utf-8')
            except (OSError, UnicodeError):
                continue
            calls.update(js_unescape(match.group(2)) for match in CALL_RE.finditer(text))
    return calls

previous, scanned, *source_roots = sys.argv[1:]
old = parse_messages(previous)
new = parse_messages(scanned)
live_calls = quoted_calls(source_roots)
for msgid in sorted(set(old) - set(new)):
    if msgid in live_calls:
        print(
            f'Translation scan dropped a message still present in source: {msgid}',
            file=sys.stderr,
        )
        sys.exit(1)
PY
}

XGETTEXT_BIN="$(command -v xgettext || true)"
[[ -n "$XGETTEXT_BIN" ]] || {
	echo "gettext's xgettext command is required for translation scanning" >&2
	exit 1
}
SCANNER_DIR="$(mktemp -d)"
XGETTEXT_FAILURE_LOG="$SCANNER_DIR/xgettext.failures"
cat > "$SCANNER_DIR/xgettext" <<'EOF'
#!/usr/bin/env bash

set +e
"$XGETTEXT_REAL" "$@"
result=$?
if (( result != 0 )); then
	printf 'xgettext invocation failed (exit %d): %s\n' "$result" "$*" >> "$XGETTEXT_FAILURE_LOG"
fi
exit "$result"
EOF
chmod 0755 "$SCANNER_DIR/xgettext"

cd "$REPO_ROOT"

if (( $# > 0 )); then
	PACKAGE_DIRS=("$@")
else
	mapfile -t PACKAGE_DIRS < <(ci_discover_packages)
fi

for package_dir in "${PACKAGE_DIRS[@]}"; do
	package_dir="${package_dir%/}"
	[[ -f "$package_dir/Makefile" ]] || {
		echo "Package Makefile not found: $package_dir/Makefile" >&2
		exit 1
	}
	[[ -d "$package_dir/po" ]] || continue

	templates=()
	if [[ -d "$package_dir/po/templates" ]]; then
		mapfile -t templates < <(
			find "$package_dir/po/templates" -maxdepth 1 -type f -name '*.pot' -print |
				sort
		)
	fi
	case "${#templates[@]}" in
		0)
			package_name="$(sed -n 's/^PKG_NAME:=//p' "$package_dir/Makefile" | head -n1)"
			[[ -n "$package_name" ]] || {
				echo "PKG_NAME not found in $package_dir/Makefile" >&2
				exit 1
			}
			package_name="${package_name#luci-app-}"
			package_name="${package_name#luci-theme-}"
			template="$package_dir/po/templates/$package_name.pot"
			;;
		1)
			template="${templates[0]}"
			;;
		*)
			echo "Multiple translation templates found in $package_dir" >&2
			exit 1
			;;
	esac

	sources=()
	for relative_path in \
		htdocs \
		luasrc \
		root/etc/init.d \
		root/etc/uci-defaults \
		root/etc/sbproxy/scripts \
		root/usr/bin \
		root/usr/libexec \
		root/usr/share/luci \
		root/usr/share/rpcd; do
		[[ -d "$package_dir/$relative_path" ]] && sources+=("$package_dir/$relative_path")
	done

	[[ "${#sources[@]}" -gt 0 ]] || continue
	mkdir -p -- "$(dirname -- "$template")"
	previous_message_count=0
	if [[ -f "$template" ]]; then
		previous_message_count="$(grep -c '^msgid ' "$template" || true)"
	fi
	POT_TEMP="$(mktemp "${template}.tmp.XXXXXX")"
	: > "$XGETTEXT_FAILURE_LOG"
	PATH="$SCANNER_DIR:$PATH" \
		XGETTEXT_REAL="$XGETTEXT_BIN" \
		XGETTEXT_FAILURE_LOG="$XGETTEXT_FAILURE_LOG" \
		perl "$SCAN_SCRIPT" "${sources[@]}" > "$POT_TEMP"
	if [[ -s "$XGETTEXT_FAILURE_LOG" ]]; then
		echo "Translation scan encountered xgettext errors for $package_dir; refusing to update translations" >&2
		cat "$XGETTEXT_FAILURE_LOG" >&2
		exit 1
	fi
	[[ -s "$POT_TEMP" ]] || {
		echo "Translation scan produced an empty template for $package_dir" >&2
		exit 1
	}
	message_count="$(grep -c '^msgid ' "$POT_TEMP" || true)"
	# A partial xgettext scan must never be allowed to remove existing
	# translations.  The old 20% threshold let smaller but still destructive
	# drops (for example 816 -> 739 messages) pass through.  A smaller catalog
	# is accepted only when every removed msgid is obsolete.
	if (( previous_message_count > 0 && message_count < previous_message_count )); then
		if ! translation_drop_is_obsolete "$template" "$POT_TEMP" "${sources[@]}"; then
			echo "Translation scan unexpectedly dropped from $previous_message_count to $message_count messages for $package_dir" >&2
			exit 1
		fi
		echo "Translation scan removed only obsolete messages ($previous_message_count -> $message_count) for $package_dir" >&2
	fi
	mv -f -- "$POT_TEMP" "$template"
	POT_TEMP=""

	perl "$UPDATE_SCRIPT" "$package_dir/po"
	find "$package_dir/po" -type f -name '*.po~' -delete
	while IFS= read -r -d '' po_file; do
		# msgmerge marks source entries missing from the newly generated POT as
		# obsolete.  Check translated obsolete entries before cleaning them;
		# otherwise a broken/incomplete scan silently deletes real translations.
		obsolete_translated_count="$(
			msgattrib --only-obsolete --translated "$po_file" |
				awk '/^#~ msgid / { count++ } END { print count + 0 }'
		)"
		if (( obsolete_translated_count > 0 )); then
			if ! translation_drop_is_obsolete "$po_file" "$template" "${sources[@]}"; then
				echo "Translation scan marked $obsolete_translated_count translated messages obsolete in $po_file; refusing to remove them" >&2
				exit 1
			fi
			echo "Removing $obsolete_translated_count obsolete translated messages from $po_file" >&2
		fi
		msgattrib --no-obsolete -o "$po_file" "$po_file"
		msgfmt --check -o /dev/null "$po_file"
		fuzzy_count="$(
			msgattrib --only-fuzzy --no-obsolete "$po_file" |
				awk '/^#,.*fuzzy/ { count++ } END { print count + 0 }'
		)"
		if (( fuzzy_count > 0 )); then
			echo "Fuzzy translation found: $po_file" >&2
			exit 1
		fi
		untranslated_count="$(
			msgattrib --untranslated --no-obsolete "$po_file" |
				awk '/^msgstr ""$/ { count++ } END { print count + 0 }'
		)"
		if (( untranslated_count > 0 )); then
			echo "Untranslated message found: $po_file" >&2
			exit 1
		fi
	done < <(find "$package_dir/po" -type f -name '*.po' -print0)

	echo "Updated translations: $package_dir"
done
