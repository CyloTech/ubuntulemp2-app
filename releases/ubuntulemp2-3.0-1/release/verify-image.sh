#!/bin/bash
# Release gate for a PHP security overlay image (settings in gate.conf).
#
# Usage: release/verify-image.sh <image-ref>
#
# A release build is repo.cylo.net/<image>:<tag>. A trial build is
# local/<image>-trial:<tag> and needs GATE_REGISTRY_REF set to the real
# repo.cylo.net/<image>:<tag>, so the registry check runs against the tag the
# release will use.
#
# The gate compares the image with the deployed base image it was built FROM,
# then runs both the way the platform does (customer volumes, container
# recreated on update) and checks that the web server still serves a PHP site
# from the customer volume, that PHP parses multipart uploads, and that the
# configuration left in the volumes is exactly what the deployed image leaves.
#
# Exits 0 only when every check passes and the registry definitively reports
# that the tag does not exist yet. Any indeterminate registry answer fails.
set -euo pipefail
export LC_ALL=C

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
warn() {
    echo "WARN: $*" >&2
}
section() {
    echo
    echo "== $*"
}

[ "$#" -eq 1 ] || fail "usage: $0 <image-ref>"
image_ref=$1
case "$image_ref" in
    ''|*[!A-Za-z0-9._/:-]*|*@*) fail "invalid image reference: $image_ref" ;;
esac
release_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=gate.conf
. "$release_dir/gate.conf"
if [ -z "${GATE_BASE_IMAGE:-}" ]; then
    # Use the image the Dockerfile builds FROM (its last stage).
    GATE_BASE_IMAGE=$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$release_dir/../Dockerfile" | tail -1)
fi
case "$GATE_BASE_IMAGE" in
    repo.cylo.net/*@sha256:????????????????????????????????????????????????????????????????) ;;
    *) fail "the base image must be a repo.cylo.net digest reference, got '$GATE_BASE_IMAGE'" ;;
esac

intended_ref="repo.cylo.net/${GATE_IMAGE_NAME}:${GATE_TAG}"
case "$image_ref" in
    "local/${GATE_IMAGE_NAME}-trial:"*)
        mode=trial
        registry_ref=${GATE_REGISTRY_REF:-}
        [ "$registry_ref" = "$intended_ref" ] \
            || fail "trial images need GATE_REGISTRY_REF=$intended_ref"
        ;;
    "$intended_ref")
        mode=release
        registry_ref=$image_ref
        if [ -n "${GATE_REGISTRY_REF:-}" ] && [ "$GATE_REGISTRY_REF" != "$image_ref" ]; then
            fail "GATE_REGISTRY_REF must not differ from the image reference in a release"
        fi
        ;;
    *) fail "image reference must be $intended_ref or local/${GATE_IMAGE_NAME}-trial:<tag>" ;;
esac
echo "Gate for $GATE_TITLE"
echo "image: $image_ref ($mode)"
echo "base:  $GATE_BASE_IMAGE"

php="php${GATE_PHP_BRANCH}"
work=$(mktemp -d)
run_id=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
prefix="gate-${GATE_IMAGE_NAME}-${run_id}"
containers=()
volumes=()
cleanup() {
    local name
    for name in "${containers[@]+"${containers[@]}"}"; do
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    for name in "${volumes[@]+"${volumes[@]}"}"; do
        docker volume rm -f "$name" >/dev/null 2>&1 || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

vercmp() {
    dpkg --compare-versions "$1" "$2" "$3"
}
part() {
    # part <file> <section>: print one "### <section>" block of probe output.
    awk -v s="### $2" '$0 == s {f = 1; next} /^### / {f = 0} f' "$1"
}

# ---------------------------------------------------------------- base image
section "Base image"
docker image inspect "$GATE_BASE_IMAGE" >/dev/null 2>&1 || docker pull -q "$GATE_BASE_IMAGE" >/dev/null
docker image inspect "$image_ref" >/dev/null 2>&1 || fail "$image_ref is not a local image"
docker image inspect -f '{{range .RootFS.Layers}}{{println .}}{{end}}' "$GATE_BASE_IMAGE" | grep . > "$work/base.layers"
docker image inspect -f '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image_ref" | grep . > "$work/image.layers"
if [ -n "${GATE_BASE_LAYERS_SHA256:-}" ]; then
    base_layers_sha=$(sha256sum < "$work/base.layers" | cut -d' ' -f1)
    [ "$base_layers_sha" = "$GATE_BASE_LAYERS_SHA256" ] \
        || fail "base image layers ($base_layers_sha) are not the deployed image's ($GATE_BASE_LAYERS_SHA256)"
    echo "base layers match the deployed image"
fi
base_count=$(wc -l < "$work/base.layers")
image_count=$(wc -l < "$work/image.layers")
[ "$image_count" -gt "$base_count" ] || fail "image adds no layers to the base"
head -n "$base_count" "$work/image.layers" | cmp -s - "$work/base.layers" \
    || fail "image is not built on $GATE_BASE_IMAGE"
echo "image = base + $((image_count - base_count)) layer(s)"

runtime_config() {
    docker image inspect --format '{{json .Config}}' "$1" \
        | jq -S '{Env, Cmd, Entrypoint, ExposedPorts, Volumes, WorkingDir, User, StopSignal, Healthcheck, Shell,
                  Labels: ((.Labels // {}) | with_entries(select(.key | startswith("net.cylo.") | not)))}'
}
runtime_config "$GATE_BASE_IMAGE" > "$work/base.config"
runtime_config "$image_ref" > "$work/image.config"
diff -u "$work/base.config" "$work/image.config" || fail "image runtime configuration differs from the base"
echo "entrypoint, command, environment, ports and volumes unchanged"

labels=$(docker image inspect --format '{{json .Config.Labels}}' "$image_ref")
min_version=$(jq -r '."net.cylo.php-min-version" // empty' <<< "$labels")
label_source=$(jq -r '."net.cylo.php-source-package" // empty' <<< "$labels")

# One container per image for all static checks (container start-up is the
# slow part on a busy builder).
section "Probing the base image and the candidate"
probe() {
    docker run --rm --network none --platform linux/amd64 -v "$release_dir:/gate:ro" \
        --entrypoint sh "$1" /gate/probe.sh "$php" "${GATE_FPM_BIN:--}" "$2" "${GATE_IMAGE_CONFIG_ROOTS[@]}"
}
probe "$GATE_BASE_IMAGE" base > "$work/base.probe" 2> "$work/base.probe.err" &
base_probe_pid=$!
probe "$image_ref" full > "$work/image.probe" 2> "$work/image.probe.err" &
image_probe_pid=$!
wait "$base_probe_pid" || { cat "$work/base.probe.err"; fail "probing the base image failed"; }
wait "$image_probe_pid" || { cat "$work/image.probe.err"; fail "probing the image failed"; }
grep -qx '### end' "$work/image.probe" || { tail -20 "$work/image.probe" "$work/image.probe.err"; fail "image probe did not finish"; }

# ------------------------------------------------------------------ packages
section "PHP packages"
[ -n "$min_version" ] && [ "$min_version" != UNSET ] || fail "image has no net.cylo.php-min-version label"
[ "$label_source" = "$GATE_PHP_SOURCE" ] || fail "image was built for source package '$label_source', expected $GATE_PHP_SOURCE"
echo "minimum $GATE_PHP_SOURCE version: $min_version"
part "$work/base.probe" pkgs > "$work/base.pkgs"
part "$work/image.probe" pkgs > "$work/image.pkgs"
awk -F'|' -v s="$GATE_PHP_SOURCE" '$3 == s {print $1 "|" $2}' "$work/base.pkgs" > "$work/base.php"
awk -F'|' -v s="$GATE_PHP_SOURCE" '$3 == s {print $1 "|" $2}' "$work/image.pkgs" > "$work/image.php"
[ -s "$work/image.php" ] || fail "no $GATE_PHP_SOURCE packages installed"
diff <(cut -d'|' -f1 "$work/base.php") <(cut -d'|' -f1 "$work/image.php") \
    || fail "the set of installed $GATE_PHP_SOURCE packages changed"
unpatched=0
while IFS='|' read -r pkg version; do
    base_version=$(awk -F'|' -v p="$pkg" '$1 == p {print $2}' "$work/base.php")
    echo "$pkg $base_version -> $version"
    vercmp "$version" ge "$min_version" || fail "$pkg $version is older than $min_version"
    vercmp "$version" gt "$base_version" || fail "$pkg was not upgraded from $base_version"
    if ! vercmp "$version" gt "$GATE_PHP_LAST_UNPATCHED"; then
        unpatched=1
    fi
done < "$work/image.php"
# The published patched version (gate.conf) is required independently of the
# image label, so a release cannot pass with a lower PHP_MIN_VERSION.
if [ -n "${GATE_PHP_PATCHED_MIN:-}" ]; then
    below_patched=0
    while IFS='|' read -r pkg version; do
        if ! vercmp "$version" ge "$GATE_PHP_PATCHED_MIN"; then
            [ "$mode" = trial ] || fail "$pkg $version is older than the patched $GATE_PHP_SOURCE $GATE_PHP_PATCHED_MIN"
            below_patched=1
            unpatched=1
        fi
    done < "$work/image.php"
    if [ "$below_patched" = 0 ]; then
        echo "every $GATE_PHP_SOURCE package is at least the patched $GATE_PHP_PATCHED_MIN"
    fi
elif [ "$mode" = release ]; then
    fail "gate.conf must set GATE_PHP_PATCHED_MIN for a release"
fi
if [ -n "${GATE_PHP_VERSION_SUFFIX:-}" ]; then
    if grep -v -F -- "$GATE_PHP_VERSION_SUFFIX" "$work/image.php" | grep -q .; then
        fail "some $GATE_PHP_SOURCE packages are not from the local rebuild ($GATE_PHP_VERSION_SUFFIX)"
    fi
fi
if [ "${GATE_REQUIRE_LOCAL_PATCHES:-0}" = 1 ]; then
    part "$work/image.probe" local-patches > "$work/local-patches"
    echo "local patches built into $GATE_PHP_SOURCE: $(grep -c . "$work/local-patches" || true)"
    sed 's/^/  /' "$work/local-patches"
    grep -q . "$work/local-patches" || unpatched=1
fi
if [ "$unpatched" = 1 ]; then
    if [ "$mode" = release ]; then
        fail "$GATE_PHP_SOURCE is not newer than the last known unpatched version $GATE_PHP_LAST_UNPATCHED"
    fi
    warn "trial image: $GATE_PHP_SOURCE is still the unpatched version (allowed only for local trial images)"
fi

# Every other package must still be installed; report what the upgrade moved.
join -t'|' -v1 "$work/base.pkgs" "$work/image.pkgs" | cut -d'|' -f1,2 > "$work/removed"
join -t'|' -v2 "$work/base.pkgs" "$work/image.pkgs" | cut -d'|' -f1,2 > "$work/added"
[ ! -s "$work/removed" ] || { sed 's/^/  /' "$work/removed"; fail "packages were removed"; }
if [ -s "$work/added" ]; then
    echo "packages added as dependencies:"
    sed 's/^/  /' "$work/added"
fi
join -t'|' -o 1.1,1.2,2.2,1.3 "$work/base.pkgs" "$work/image.pkgs" \
    | awk -F'|' -v s="$GATE_PHP_SOURCE" '$4 != s && $2 != $3 {print "  " $1 " " $2 " -> " $3}' > "$work/other-upgrades"
if [ -s "$work/other-upgrades" ]; then
    echo "other packages upgraded with $GATE_PHP_SOURCE:"
    cat "$work/other-upgrades"
fi

# ------------------------------------------------------------ static checks
section "PHP binaries and modules"
version_line=$(part "$work/image.probe" php-version)
echo "$version_line"
case "$version_line" in
    "PHP ${GATE_PHP_BRANCH}."*) ;;
    *) fail "$php is not PHP $GATE_PHP_BRANCH" ;;
esac
if [ -n "${GATE_PHP_DEFAULT_CLI:-}" ]; then
    php_alternative=$(part "$work/image.probe" php-alternative)
    [ "$php_alternative" = "$GATE_PHP_DEFAULT_CLI" ] || fail "/usr/bin/php is $php_alternative, expected $GATE_PHP_DEFAULT_CLI"
    echo "/usr/bin/php -> $php_alternative"
fi
compare_modules() {
    local name=$1
    part "$work/base.probe" "$name" > "$work/base.$name"
    part "$work/image.probe" "$name" > "$work/image.$name"
    [ -s "$work/image.$name" ] || fail "$name: empty"
    diff -u "$work/base.$name" "$work/image.$name" || fail "$name differs from the base image"
    if [ -f "$release_dir/expected/$name.txt" ]; then
        diff -u "$release_dir/expected/$name.txt" "$work/image.$name" || fail "$name differs from expected/$name.txt"
    fi
    echo "$name: $(grep -c . "$work/image.$name") lines, same as the deployed image"
}
compare_modules cli-modules
if [ -n "${GATE_FPM_BIN:-}" ]; then
    compare_modules fpm-modules
    [ "$(part "$work/image.probe" fpm-test | tail -1)" = ok ] \
        || { part "$work/image.probe" fpm-test; fail "$GATE_FPM_BIN -t failed"; }
    echo "$GATE_FPM_BIN -t: ok"
fi

section "Packaged configuration and scripts"
part "$work/base.probe" files > "$work/base.files"
part "$work/image.probe" files > "$work/image.files"
[ -s "$work/image.files" ] || fail "no files found under ${GATE_IMAGE_CONFIG_ROOTS[*]}"
# Paths, types, modes and owners must be identical everywhere.
diff -u <(grep -v '^[0-9a-f]\{64\}  ' "$work/base.files") <(grep -v '^[0-9a-f]\{64\}  ' "$work/image.files") \
    || fail "configuration paths, modes or owners changed"
# Content may change only where gate.conf allows it (PHP's own ini defaults);
# everything else must be byte-identical.
{ diff <(grep '^[0-9a-f]\{64\}  ' "$work/base.files") <(grep '^[0-9a-f]\{64\}  ' "$work/image.files") || true; } \
    | sed -n 's/^> [0-9a-f]\{64\}  //p' > "$work/changed-files"
if [ -s "$work/changed-files" ]; then
    echo "files whose content changed:"
    sed 's/^/  /' "$work/changed-files"
    if grep -v -E "${GATE_CONTENT_CHANGE_ALLOWED:-^$}" "$work/changed-files" | grep -q .; then
        fail "configuration or scripts changed outside the allowed PHP ini files"
    fi
    warn "PHP's packaged ini defaults changed (allowed by gate.conf)"
fi
echo "$(grep -c '^[0-9a-f]\{64\}  ' "$work/image.files") files under ${GATE_IMAGE_CONFIG_ROOTS[*]} have the same paths, modes and owners"

section "Multipart upload through the CLI built-in server"
part "$work/image.probe" cli-multipart
[ "$(part "$work/image.probe" cli-multipart | tail -1)" = ok ] || fail "multipart upload through the CLI server failed"

section "Regression checks (release/regression/*.sh)"
if part "$work/image.probe" regression | grep -q .; then
    part "$work/image.probe" regression
    if part "$work/image.probe" regression | grep -q '^failed'; then
        fail "a regression check failed"
    fi
else
    echo "none"
fi

# ---------------------------------------------------- platform-style runs
volume_index() {
    local i=0 path
    for path in "${GATE_VOLUMES[@]}"; do
        if [ "$path" = "$1" ]; then
            echo "$i"
            return 0
        fi
        i=$((i + 1))
    done
    fail "$1 is not in GATE_VOLUMES"
}
volume_index "$GATE_DOCROOT" >/dev/null
for path in "${GATE_CONFIG_VOLUMES[@]}"; do volume_index "$path" >/dev/null; done

create_container() {
    # create_container <name> <image> <volume-set>: created like the platform
    # does (init, the app's volumes), not started yet.
    local name=$1 image=$2 set=$3 i=0 path
    local args=(docker create --name "$name" --init --platform linux/amd64 --network "$GATE_RUN_NETWORK")
    for path in "${GATE_RUN_ENV[@]+"${GATE_RUN_ENV[@]}"}"; do
        args+=(-e "$path")
    done
    for path in "${GATE_RUN_STUBS[@]+"${GATE_RUN_STUBS[@]}"}"; do
        # <file in release/stubs>:<path in the container>, read-only
        args+=(--mount "type=bind,src=$release_dir/stubs/${path%%:*},dst=${path#*:},readonly")
    done
    for path in "${GATE_VOLUMES[@]}"; do
        if ! docker volume inspect "$prefix-$set-$i" >/dev/null 2>&1; then
            docker volume create "$prefix-$set-$i" >/dev/null
            volumes+=("$prefix-$set-$i")
        fi
        args+=(--mount "type=volume,src=$prefix-$set-$i,dst=$path,volume-nocopy")
        i=$((i + 1))
    done
    containers+=("$name")
    "${args[@]}" "$image" >/dev/null
}

seed_site() {
    # seed_site <container>: put the gate pages into the docroot volume, like
    # a customer's site.
    docker cp -q "$release_dir/site/." "$1:$GATE_DOCROOT/"
}

http() {
    # http <container> <probe|info|upload>
    docker exec -i "$1" "$php" -- "$2" "$GATE_HTTP_PORT" < "$release_dir/http-check.php"
}

wait_ready() {
    # wait_ready <container> [site]: wait until the web server answers and,
    # with "site", serves the PHP page.
    local name=$1 want_site=${2:-} deadline=$((SECONDS + GATE_READY_TIMEOUT)) attempt
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
            docker logs --tail 60 "$name" 2>&1 | sed 's/^/  | /'
            fail "$name exited during start-up"
        fi
        if http "$name" probe >/dev/null 2>&1; then
            [ -n "$want_site" ] || return 0
            for attempt in $(seq 1 30); do
                http "$name" info >/dev/null 2>&1 && return 0
                sleep 2
            done
            docker logs --tail 60 "$name" 2>&1 | sed 's/^/  | /'
            http "$name" info || true
            fail "$name answers HTTP but does not serve the PHP page"
        fi
        sleep 3
    done
    docker logs --tail 60 "$name" 2>&1 | sed 's/^/  | /'
    fail "$name did not start serving within ${GATE_READY_TIMEOUT}s"
}

remove_container() {
    docker stop -t 30 "$1" >/dev/null
    docker rm "$1" >/dev/null
}

check_services() {
    # check_services <container>: runtime configuration tests and databases.
    local name=$1 check deadline
    for check in "${GATE_RUNTIME_CHECKS[@]+"${GATE_RUNTIME_CHECKS[@]}"}"; do
        docker exec "$name" sh -c "$check" > "$work/check.out" 2>&1 \
            || { cat "$work/check.out"; fail "$name: '$check' failed"; }
        echo "ok: $check"
    done
    if [ -n "${GATE_DB_CHECK:-}" ]; then
        deadline=$((SECONDS + GATE_READY_TIMEOUT))
        until docker exec "$name" sh -c "$GATE_DB_CHECK" > "$work/check.out" 2>&1; do
            if [ "$SECONDS" -ge "$deadline" ]; then
                cat "$work/check.out"
                docker logs --tail 40 "$name" 2>&1 | sed 's/^/  | /'
                fail "$name: database is not running ($GATE_DB_CHECK)"
            fi
            sleep 3
        done
        echo "ok: $GATE_DB_CHECK"
    fi
}

check_site() {
    # check_site <container>: the PHP page and a multipart upload through the
    # image's own web server and PHP SAPI.
    local name=$1
    http "$name" info > "$work/$name.info" || { cat "$work/$name.info"; fail "$name does not serve the PHP page"; }
    grep -qx "sapi=${GATE_SAPI}" "$work/$name.info" || { head -3 "$work/$name.info"; fail "$name serves PHP through the wrong SAPI"; }
    grep -q "^version=${GATE_PHP_BRANCH}\." "$work/$name.info" || { head -3 "$work/$name.info"; fail "$name serves the wrong PHP branch"; }
    grep -E '^(ext|zend)=' "$work/$name.info" > "$work/$name.modules"
    echo "$name: $(grep '^version=' "$work/$name.info") via $GATE_SAPI, $(wc -l < "$work/$name.modules") modules"
    http "$name" upload || fail "$name: multipart upload through the web server failed"
}

snapshot_config() {
    # snapshot_config <container>: paths, modes, owners and content of the
    # configuration volumes, read inside the running container.
    local name=$1 path
    for path in "${GATE_CONFIG_VOLUMES[@]}"; do
        echo "## $path"
        docker exec "$name" sh -c \
            'cd "$1" && find . -printf "%y %m %U:%G %p -> %l\n" | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum' \
            sh "$path"
    done
}

section "Update from the deployed image (same volumes, container recreated)"
# Two volume sets start with the deployed image and a customer site. "ref" is
# then recreated from the deployed image again, "upd" from this image; the
# configuration volumes must end up identical, and the site must still work.
create_container "$prefix-ref1" "$GATE_BASE_IMAGE" ref
create_container "$prefix-upd1" "$GATE_BASE_IMAGE" upd
seed_site "$prefix-ref1"
seed_site "$prefix-upd1"
docker start "$prefix-ref1" "$prefix-upd1" >/dev/null
wait_ready "$prefix-ref1" site
wait_ready "$prefix-upd1" site
echo "deployed image is serving the site on both volume sets"
remove_container "$prefix-ref1"
remove_container "$prefix-upd1"

create_container "$prefix-ref2" "$GATE_BASE_IMAGE" ref
create_container "$prefix-upd2" "$image_ref" upd
create_container "$prefix-new" "$image_ref" new
docker start "$prefix-ref2" "$prefix-upd2" "$prefix-new" >/dev/null
wait_ready "$prefix-ref2" site
wait_ready "$prefix-upd2" site
http "$prefix-ref2" info | grep -E '^(ext|zend)=' > "$work/base.site-modules"
snapshot_config "$prefix-ref2" > "$work/ref.config-volumes"
check_site "$prefix-upd2"
diff -u "$work/base.site-modules" "$work/$prefix-upd2.modules" \
    || fail "modules loaded for the site differ from the deployed image"
if [ -f "$release_dir/expected/site-modules.txt" ]; then
    diff -u "$release_dir/expected/site-modules.txt" "$work/$prefix-upd2.modules" \
        || fail "modules loaded for the site differ from expected/site-modules.txt"
fi
check_services "$prefix-upd2"
snapshot_config "$prefix-upd2" > "$work/upd.config-volumes"
diff -u "$work/ref.config-volumes" "$work/upd.config-volumes" \
    || fail "after the update the configuration volumes differ from the deployed image's"
echo "configuration volumes after the update are identical to the deployed image's ($(grep -c . "$work/upd.config-volumes") entries)"

section "Fresh install"
wait_ready "$prefix-new"
seed_site "$prefix-new"
check_site "$prefix-new"
check_services "$prefix-new"
for name in "$prefix-ref2" "$prefix-upd2" "$prefix-new"; do
    remove_container "$name"
done

# ------------------------------------------------------------------ registry
section "Registry tag must not exist"
registry=${registry_ref%%/*}
repository_and_tag=${registry_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || fail "image reference has no tag"

registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || fail "no stored credentials for $registry"

registry_body="$work/registry-body"
registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS -K - -o "$registry_body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}

api_status=$(registry_get /v2/) || fail "registry unreachable"
[ "$api_status" = 200 ] || fail "registry API check returned HTTP $api_status"

manifest_status=$(registry_get "/v2/$repository/manifests/$tag") || fail "registry unreachable"
case "$manifest_status" in
    200) fail "$registry_ref already exists in the registry" ;;
    404)
        grep -q 'MANIFEST_UNKNOWN' "$registry_body" \
            || fail "registry returned 404 without MANIFEST_UNKNOWN: $(head -c 300 "$registry_body")"
        echo "$registry_ref is not in the registry yet"
        ;;
    *) fail "registry returned HTTP $manifest_status for $registry_ref" ;;
esac

if [ "$mode" = trial ]; then
    echo "PASS (trial): $image_ref; registry tag $registry_ref is free"
else
    echo "PASS: $image_ref"
fi
