#!/usr/bin/env bash
# Behavior tests for bin/fm-image-review.sh: recursive discovery, tab and
# nested-section grouping, stable root-relative image ids, hidden and
# non-image exclusion, --out handling (default, custom, outside-walk
# exclusion), idempotent reruns, empty directories, and refusal paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-image-review)
GEN="$ROOT/bin/fm-image-review.sh"

# A recognizable non-empty PNG header; the generator never decodes image
# bytes, so the fixture only needs image-extension files on disk.
write_png() {
  printf '\211PNG\r\n\032\n' > "$1"
}

make_tree() {
  local base=$1
  mkdir -p "$base/alpha/art1/run-a" "$base/alpha/art1/run-b" "$base/beta/run-c" "$base/emptydir"
  write_png "$base/alpha/art1/run-a/one.png"
  write_png "$base/alpha/art1/run-a/two.jpeg"
  write_png "$base/alpha/art1/run-b/three.jpg"
  write_png "$base/beta/run-c/four.webp"
  write_png "$base/000-root.gif"
}

# The C-locale sorted walk over make_tree's layout yields these root-relative
# ids, in this order.
TREE_IDS="000-root.gif|alpha/art1/run-a/one.png|alpha/art1/run-a/two.jpeg|alpha/art1/run-b/three.jpg|beta/run-c/four.webp|"

ids_in_order() {
  grep -o 'data-image-id="[^"]*"' "$1" | sed 's/^data-image-id="//; s/"$//' | uniq | tr '\n' '|'
}

tab_labels_in_order() {
  grep -o 'class="tab[^"]*"[^>]*>[^<]*<' "$1" | sed 's/.*>//; s/<$//' | tr '\n' '|'
}

summaries_in_order() {
  grep -o '<summary>[^<]*</summary>' "$1" | sed 's/<[^>]*>//g' | tr '\n' '|'
}

test_recursive_discovery_and_stable_ids() {
  local base out
  base="$TMP_ROOT/discover"
  make_tree "$base"
  out=$(bash "$GEN" "$base")
  assert_contains "$out" "(5 images, 3 groups)" "discovery summary did not report 5 images and 3 groups"
  assert_present "$base/.image-review.html" "default page was not written inside the images root"
  assert_equals "$(ids_in_order "$base/.image-review.html")" "$TREE_IDS" \
    "data-image-id values did not equal the root-relative paths in walk order"
  assert_contains "$out" "image-review: $base/.image-review.html" "result line did not name the page path"
  pass "fm-image-review.sh: recursive discovery yields stable root-relative image ids"
}

test_grouping_tabs_and_nested_collapse_sections() {
  local base page
  base="$TMP_ROOT/grouping"
  make_tree "$base"
  bash "$GEN" "$base" >/dev/null
  page="$base/.image-review.html"
  assert_equals "$(tab_labels_in_order "$page")" "(root)|alpha|beta|" \
    "tab labels were not the top-level segments in walk order"
  assert_equals "$(summaries_in_order "$page")" "art1|run-a|run-b|run-c|" \
    "nested collapsible sections did not mirror the directory levels"
  assert_no_grep '<summary>one.png' "$page" "a leaf image file became a collapsible section"
  assert_no_grep '<summary>000-root.gif' "$page" "a root-level file became a collapsible section"
  assert_grep 'loading="lazy"' "$page" "thumbnails were not lazy-loaded"
  assert_grep 'data-full="alpha/art1/run-a/one.png"' "$page" "thumbnail did not carry its full-size target"
  assert_grep '<details open><summary>art1</summary>' "$page" "nested sections were not collapsible details"
  assert_grep '<section class="pane active" id="pane-0">' "$page" "the first pane did not start visible beside its active tab"
  pass "fm-image-review.sh: tabs and nested collapsible sections mirror the tree"
}

test_idempotent_rerun_rewrites_identical_bytes() {
  local base before after
  base="$TMP_ROOT/idempotent"
  make_tree "$base"
  bash "$GEN" "$base" >/dev/null
  before=$(cksum < "$base/.image-review.html")
  bash "$GEN" "$base" >/dev/null
  after=$(cksum < "$base/.image-review.html")
  assert_equals "$before" "$after" "a rerun over an unchanged tree changed the page bytes"
  pass "fm-image-review.sh: rerun over an unchanged tree is byte-identical"
}

test_excludes_non_images_and_hidden_entries() {
  local base page
  base="$TMP_ROOT/exclusion"
  mkdir -p "$base/.hidden-dir" "$base/docs"
  make_tree "$base"
  write_png "$base/.DS_Store.png"
  write_png "$base/.hidden-dir/secret.png"
  printf 'not an image\n' > "$base/alpha/notes.txt"
  printf '# readme\n' > "$base/README.md"
  write_png "$base/beta/IMG_0001.JPG"
  write_png "$base/beta/mov.BMP"
  bash "$GEN" "$base" >/dev/null
  page="$base/.image-review.html"
  # C-locale order: "I" sorts before "r" inside beta/
  assert_equals "$(ids_in_order "$page")" \
    "000-root.gif|alpha/art1/run-a/one.png|alpha/art1/run-a/two.jpeg|alpha/art1/run-b/three.jpg|beta/IMG_0001.JPG|beta/run-c/four.webp|" \
    "exclusion kept a non-image, a hidden entry, or lost the uppercase-extension image"
  assert_no_grep 'notes.txt' "$page" "a non-image file leaked into the page"
  assert_no_grep 'README.md' "$page" "a markdown file leaked into the page"
  assert_no_grep 'DS_Store' "$page" "a hidden file leaked into the page"
  assert_no_grep 'secret.png' "$page" "a hidden-directory image leaked into the page"
  assert_no_grep 'mov.BMP' "$page" "an unsupported extension leaked into the page"
  pass "fm-image-review.sh: excludes non-images and hidden entries, keeps uppercase extensions"
}

test_default_out_and_custom_out_relative_refs() {
  local base out
  base="$TMP_ROOT/out-handling"
  make_tree "$base"
  out=$(bash "$GEN" "$base" --out "$base/review.html" --title "Custom title")
  assert_present "$base/review.html" "custom --out page was not written"
  assert_grep '<title>Custom title</title>' "$base/review.html" "--title was not applied"
  assert_equals "$(ids_in_order "$base/review.html")" "$TREE_IDS" \
    "custom --out changed the image ids"
  assert_grep 'src="alpha/art1/run-a/one.png"' "$base/review.html" \
    "a page beside the tree root did not reference images relatively"

  mkdir -p "$base/nested/dir"
  out=$(bash "$GEN" "$base" --out "$base/nested/dir/page.html")
  assert_present "$base/nested/dir/page.html" "deeper --out page was not written"
  assert_grep 'src="../../alpha/art1/run-a/one.png"' "$base/nested/dir/page.html" \
    "a page nested inside the root did not reference images with .. segments"
  pass "fm-image-review.sh: --out destinations compute correct relative image refs"
}

test_out_inside_root_is_excluded_from_its_own_walk() {
  local base before after
  base="$TMP_ROOT/out-walk"
  make_tree "$base"
  # The page name carries an image extension, so only the explicit path
  # exclusion can keep a rerun byte-identical.
  bash "$GEN" "$base" --out "$base/report.png" >/dev/null
  before=$(cksum < "$base/report.png")
  bash "$GEN" "$base" --out "$base/report.png" >/dev/null
  after=$(cksum < "$base/report.png")
  assert_equals "$before" "$after" "the page's own file leaked into a rerun's walk"
  assert_equals "$(ids_in_order "$base/report.png")" "$TREE_IDS" \
    "the page's own file appeared as an image id"
  pass "fm-image-review.sh: the page itself never leaks into the walk"
}

test_empty_directories_produce_no_sections() {
  local base page
  base="$TMP_ROOT/empty-dirs"
  make_tree "$base"
  bash "$GEN" "$base" >/dev/null
  page="$base/.image-review.html"
  assert_no_grep 'emptydir' "$page" "an image-less directory produced a tab or section"
  pass "fm-image-review.sh: empty directories produce no tabs or sections"
}

test_feedback_controls_map_to_image_ids() {
  local base page
  base="$TMP_ROOT/feedback"
  make_tree "$base"
  bash "$GEN" "$base" >/dev/null
  page="$base/.image-review.html"
  assert_grep 'queuePrompt' "$page" "feedback form did not queue through lavish"
  assert_grep 'queueKey' "$page" "queued feedback did not use a stable per-image queue key"
  assert_grep 'sendQueuedPrompts' "$page" "page lacked a send-all control"
  assert_grep '<form class="fb" data-image-id="alpha/art1/run-a/one.png">' "$page" \
    "an image card's feedback form was not bound to its image id"
  assert_grep 'data-lavish-action="lightbox-close"' "$page" "lightbox backdrop was not a feedback control"
  pass "fm-image-review.sh: per-image feedback controls map comments to image ids"
}

test_default_title_uses_root_basename() {
  local base page
  base="$TMP_ROOT/title-default"
  make_tree "$base"
  bash "$GEN" "$base" >/dev/null
  page="$base/.image-review.html"
  assert_grep '<title>Image review: title-default</title>' "$page" "default title did not name the root"
  assert_grep '<h1>Image review: title-default</h1>' "$page" "default heading did not name the root"
  pass "fm-image-review.sh: default title names the images root"
}

test_refusal_paths() {
  local base out rc
  base="$TMP_ROOT/refusals"
  mkdir -p "$base/nothing-here"
  out=$(bash "$GEN" "$base/nothing-here" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a root with no reviewable images"
  assert_contains "$out" "no reviewable images" "image-less root refusal was not explained"

  out=$(bash "$GEN" "$base/does-not-exist" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a missing root"
  assert_contains "$out" "not a directory" "missing-root refusal was not explained"

  out=$(bash "$GEN" "$base/nothing-here" --bogus 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for an unknown flag"
  assert_contains "$out" "usage:" "unknown-flag refusal did not print usage"

  out=$(bash "$GEN" "$base/nothing-here" --out "$base/no-such-dir/page.html" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when --out's parent is missing"
  assert_contains "$out" "parent directory does not exist" "missing --out parent refusal was not explained"
  pass "fm-image-review.sh: refuses image-less roots, missing roots, unknown flags, and missing --out parents"
}

test_recursive_discovery_and_stable_ids
test_grouping_tabs_and_nested_collapse_sections
test_idempotent_rerun_rewrites_identical_bytes
test_excludes_non_images_and_hidden_entries
test_default_out_and_custom_out_relative_refs
test_out_inside_root_is_excluded_from_its_own_walk
test_empty_directories_produce_no_sections
test_feedback_controls_map_to_image_ids
test_default_title_uses_root_basename
test_refusal_paths
