#!/usr/bin/env bash
# Publishes to the gh-pages branch, which GitHub Pages serves.
#   publish_pages.sh site <dir>              replace the public site, keeping preview/
#   publish_pages.sh preview <number> <dir>  write preview/pr-<number>/
#   publish_pages.sh remove <number>         delete preview/pr-<number>/
# Needs GH_TOKEN and GITHUB_REPOSITORY. Other jobs may push at the same time, so the change is
# reapplied on a fresh copy of the branch until the push succeeds.
set -euo pipefail

mode="$1"
# PAGES_REMOTE replaces the GitHub address in local tests.
remote="${PAGES_REMOTE:-https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git}"
branch="gh-pages"
work="$(mktemp -d)"

case "$mode" in
    site) src="$(realpath "$2")"; message="Publish site" ;;
    preview)
        [[ "$2" =~ ^[0-9]+$ ]] || { echo "pull request number expected" >&2; exit 1; }
        number="$2"; src="$(realpath "$3")"; message="Publish preview of pull request $number" ;;
    remove)
        [[ "$2" =~ ^[0-9]+$ ]] || { echo "pull request number expected" >&2; exit 1; }
        number="$2"; message="Remove preview of pull request $number" ;;
    *) echo "unknown mode $mode" >&2; exit 1 ;;
esac

apply() {
    case "$mode" in
        site)
            find . -mindepth 1 -maxdepth 1 ! -name .git ! -name preview -exec rm -rf {} +
            cp -a "$src"/. .
            ;;
        preview)
            rm -rf "preview/pr-$number"
            mkdir -p "preview/pr-$number"
            cp -a "$src"/. "preview/pr-$number"/
            # The preview says what it is on every page load.
            banner="<p style=\"margin:0;padding:.5rem 1rem;background:#16181a;color:#f6f5f1;font:600 .95rem system-ui,sans-serif\">Preview of pull request #$number. This is not the published site.</p>"
            sed -i "0,/<body>/s||<body>\n$banner|" "preview/pr-$number/index.html"
            ;;
        remove)
            rm -rf "preview/pr-$number"
            ;;
    esac
    touch .nojekyll
}

for attempt in 1 2 3 4 5; do
    rm -rf "$work/pages"
    if git ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
        git clone -q --depth 1 --branch "$branch" "$remote" "$work/pages"
    else
        git init -q "$work/pages"
        git -C "$work/pages" checkout -q --orphan "$branch"
        git -C "$work/pages" remote add origin "$remote"
    fi
    cd "$work/pages"
    apply
    git add -A
    if git diff --cached --quiet; then
        echo "Nothing to publish"
        exit 0
    fi
    git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -q -m "$message"
    if git push -q origin "HEAD:$branch"; then
        echo "$message: done"
        exit 0
    fi
    echo "Push was rejected, retrying ($attempt)"
    sleep $((attempt * 3))
done
echo "Could not publish after 5 attempts" >&2
exit 1
