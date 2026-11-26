#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

pdfs=(./*.pdf)
pdf_total=${#pdfs[@]}

if (( pdf_total == 0 )); then
    echo "[error] No PDF found in $(pwd)"
    exit 1
fi

echo "[step 1/4] Creating directories (img, img_tmp)"
mkdir -p img img_tmp

echo "[step 2/4] Extracting images from ${pdf_total} PDF(s)"
pdf_index=0
for pdf in "${pdfs[@]}"; do
    pdf_index=$((pdf_index + 1))
    name="${pdf##*/}"
    name="${name%.pdf}"
    prefix="${name//[^[:alnum:]]/_}"

    before=$(find img_tmp -maxdepth 1 -name '*.png' | wc -l)
    pdfimages -png "$pdf" "img_tmp/${prefix}"
    after=$(find img_tmp -maxdepth 1 -name '*.png' | wc -l)

    echo "  [${pdf_index}/${pdf_total}] ${name}: +$((after - before)) image(s) | remaining PDFs: $((pdf_total - pdf_index))"
done

files=(img_tmp/*.png)
file_total=${#files[@]}
echo "[step 3/4] Deduplicating ${file_total} extracted image(s) by md5"

declare -A seen
file_index=0
kept=0
skipped=0
for file in "${files[@]}"; do
    file_index=$((file_index + 1))
    hash="$(md5sum "$file" | cut -d' ' -f1)"
    if [[ -z "${seen[$hash]:-}" ]]; then
        seen[$hash]=1
        mv -- "$file" img/
        kept=$((kept + 1))
        status="kept"
    else
        skipped=$((skipped + 1))
        status="duplicate"
    fi
    echo "  [${file_index}/${file_total}] ${status}: ${file##*/} | remaining: $((file_total - file_index))"
done

echo "[step 4/4] Removing temporary directory (img_tmp)"
rm -rf img_tmp

echo "[done] ${kept} unique image(s) in img/, ${skipped} duplicate(s) discarded, ${pdf_total} PDF(s) processed"
