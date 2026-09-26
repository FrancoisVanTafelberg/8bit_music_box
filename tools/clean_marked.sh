#!/usr/bin/env bash
# Delete every file marked for deletion, and its marker. The twin of
# tools/clean_marked.bat - see that file for why the convention exists.
set -eu
cd "$(dirname "$0")/.."

count=0
while IFS= read -r -d '' marker; do
    target="${marker%.delete}"
    if [ -e "$target" ]; then
        echo "  deleting $target"
        rm -f "$target"
        count=$((count + 1))
    else
        echo "  already gone: $target"
    fi
    rm -f "$marker"
done < <(find . -name '*.delete' -type f -print0)

echo
echo "$count marked file(s) deleted."
