#!/bin/bash
# Build this release directory on the Appbox builder from the pushed commit.
#
# Usage (from a clean checkout of this branch):
#   release/builder-release.sh trial     build local/<image>-trial:<tag> with
#                                        the trial build args from gate.conf
#                                        and run the gate; never pushes
#   release/builder-release.sh release   build repo.cylo.net/<image>:<tag>,
#                                        run the gate, then push
#
# The build context is exactly this release directory at HEAD, taken with
# `git archive <commit>:<dir>` from a commit that is on the remote branch.
set -euo pipefail

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mode=${1:-}
case "$mode" in
    trial|release) ;;
    *) fail "usage: $0 trial|release" ;;
esac

release_dir=$(cd "$(dirname "$0")" && pwd)
context_dir=$(dirname "$release_dir")
repo=$(git -C "$context_dir" rev-parse --show-toplevel)
context_path=$(git -C "$context_dir" rev-parse --show-prefix)
context_path=${context_path%/}
[ -n "$context_path" ] || fail "release directory must not be the repository root"
# shellcheck source=gate.conf
. "$release_dir/gate.conf"

# The dedicated Appbox builder (builder1, Docker 29 with buildx, logged in to
# repo.cylo.net). The old builder.grant.appboxes.co:12246 is no longer used.
builder=appbox@builder1.builder.appboxes.co
builder_port=10112
ssh_opts=(-i /Users/rid/.ssh/appbox_ubuntuvps2_webtop -o IdentitiesOnly=yes -o BatchMode=yes
          -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o ServerAliveInterval=30)

slug=$GATE_IMAGE_NAME
tag=$GATE_TAG
case "$slug" in ''|*[!A-Za-z0-9._-]*) fail "invalid image name" ;; esac
case "$tag" in ''|*[!A-Za-z0-9._-]*) fail "invalid tag" ;; esac
case "$context_path" in ''|/*|*..*|*[!A-Za-z0-9_./-]*) fail "invalid context path" ;; esac
release_ref="repo.cylo.net/$slug:$tag"
if [ "$mode" = trial ]; then
    image_ref="local/$slug-trial:$tag"
else
    image_ref=$release_ref
fi

[ -z "$(git -C "$repo" status --porcelain)" ] || fail "commit or stash local changes first"
commit=$(git -C "$repo" rev-parse HEAD)
branch=$(git -C "$repo" symbolic-ref --short HEAD)
case "$branch" in
    master|main|libvirt) fail "refusing to build from $branch" ;;
esac
remote=${RELEASE_REMOTE:-origin}
if git -C "$repo" fetch -q "$remote" "$branch" 2>/dev/null \
        && [ "$(git -C "$repo" rev-parse FETCH_HEAD)" = "$commit" ]; then
    echo "commit $commit is $remote/$branch"
elif [ "$mode" = trial ] && [ "${ALLOW_UNPUSHED_TRIAL:-0}" = 1 ]; then
    echo "WARNING: trial of commit $commit, which is not on $remote/$branch" >&2
else
    fail "HEAD $commit is not the pushed $remote/$branch; push it first"
fi

stage=$(mktemp -d /private/tmp/cylo-app-build.XXXXXX)
remote_dir=
cleanup() {
    case "$stage" in /private/tmp/cylo-app-build.??????) rm -rf "$stage" ;; esac
    case "$remote_dir" in
        "/home/appbox/builds/$slug.$tag".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]])
            ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" "rm -rf '$remote_dir'" \
                || echo "clean up $builder:$remote_dir by hand" >&2
            ;;
    esac
}
trap cleanup EXIT

archive="$stage/context.tgz"
git -C "$repo" archive --format=tar.gz --output="$archive" "$commit:$context_path"
echo "context $commit:$context_path"
tar -tzf "$archive" | sed 's/^/  /'
if tar -tzf "$archive" | grep -v -E '^(\./)?(Dockerfile|\.dockerignore|README\.md|release/.*|php72-patches/.*)$' | grep -q .; then
    fail "unexpected files in the build context"
fi
archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
echo "context.tgz sha256 $archive_sha"

remote_prefix="/home/appbox/builds/$slug.$tag"
remote_dir=$(ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" "mktemp -d '$remote_prefix.XXXXXX'")
case "$remote_dir" in
    "$remote_prefix".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]) ;;
    *) remote_dir=; fail "unexpected builder directory" ;;
esac
echo "builder directory $remote_dir"
scp -q -P "$builder_port" "${ssh_opts[@]}" "$archive" "$builder:$remote_dir/context.tgz"
ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" \
    "cd '$remote_dir' && printf '%s  context.tgz\n' '$archive_sha' | sha256sum -c - && mkdir context && tar xzf context.tgz -C context"

build_args=()
if [ "$mode" = trial ]; then
    for arg in "${GATE_TRIAL_BUILD_ARGS[@]+"${GATE_TRIAL_BUILD_ARGS[@]}"}"; do
        case "$arg" in *[!A-Za-z0-9._+=:~-]*) fail "invalid trial build arg: $arg" ;; esac
        build_args+=("--build-arg '$arg'")
    done
    ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" \
        "cd '$remote_dir/context' && \
        docker build --builder default --no-cache --platform linux/amd64 --progress=plain ${build_args[*]+${build_args[*]}} -t '$image_ref' . && \
        GATE_REGISTRY_REF='$release_ref' ./release/verify-image.sh '$image_ref'"
    echo "TRIAL PASSED: $image_ref from $commit (not pushed)"
else
    ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" \
        "cd '$remote_dir/context' && \
        docker build --builder default --no-cache --platform linux/amd64 --progress=plain -t '$image_ref' . && \
        ./release/verify-image.sh '$image_ref' && \
        docker push '$image_ref' && \
        docker buildx imagetools inspect '$image_ref' | sed -n 's/^Digest: *//p'"
    echo "PUSHED: $image_ref from $commit"
fi
