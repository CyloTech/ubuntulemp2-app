#!/bin/sh
# Runs inside an image (base or candidate) for the release gate and prints
# sections that verify-image.sh compares.
#
# Usage: sh /gate/probe.sh <php-binary> <fpm-binary or -> <full|base> <config roots...>
set -u
php=$1
fpm=$2
depth=$3
shift 3

echo "### pkgs"
dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${Version}|${source:Package}\n' \
    | awk -F'|' '$1 ~ /^.i/ {print $2 "|" $3 "|" $4}' | LC_ALL=C sort -t'|' -k1,1

echo "### php-version"
"$php" -v 2>/dev/null | grep '^PHP ' | head -1

echo "### php-alternative"
readlink -f /usr/bin/php || true

echo "### cli-modules"
"$php" -m 2>/dev/null

if [ "$fpm" != - ]; then
    echo "### fpm-modules"
    "$fpm" -m 2>/dev/null
    echo "### fpm-test"
    if "$fpm" -t >/tmp/gate-fpm-test 2>&1; then echo ok; else cat /tmp/gate-fpm-test; echo failed; fi
fi

echo "### local-patches"
if [ -f /usr/share/cylo/php-local-patches ]; then cat /usr/share/cylo/php-local-patches; fi

echo "### files"
roots=""
for root in "$@"; do
    if [ -e "$root" ] || [ -L "$root" ]; then roots="$roots $root"; fi
done
if [ -n "$roots" ]; then
    # shellcheck disable=SC2086
    find $roots -xdev -printf '%y %m %U:%G %p -> %l\n' | LC_ALL=C sort
    # shellcheck disable=SC2086
    find $roots -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
fi

[ "$depth" = full ] || exit 0

echo "### cli-multipart"
"$php" -S 127.0.0.1:8089 -t /gate/site >/dev/null 2>&1 &
server=$!
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    "$php" /gate/http-check.php probe 8089 >/dev/null 2>&1 && break
    sleep 0.5
done
if "$php" /gate/http-check.php upload 8089; then echo ok; else echo failed; fi
kill "$server" 2>/dev/null || true

echo "### regression"
for check in /gate/regression/*.sh; do
    [ -e "$check" ] || continue
    if GATE_PHP=$php sh "$check"; then
        echo "ok $(basename "$check")"
    else
        echo "failed $(basename "$check")"
    fi
done
echo "### end"
