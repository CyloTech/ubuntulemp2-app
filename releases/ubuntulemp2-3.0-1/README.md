# ubuntulemp2 3.0-1 (Lemp Stack, app 112)

Security rebuild for the PHP release of 21 October 2026 (multipart/form-data
parsing fixes). The image is the current Lemp Stack 3.0 image, `repo.cylo.net/ubuntulemp2@sha256:3897de3627f7b2d6eb5397eb0c73e6cb5ff1b58a402dfcb713449a333bee2acc` (Ubuntu 24.04 baseimage, php8.3 from the Ubuntu archive), with only the PHP packages
replaced; the PHP branch, web server, scripts and default configuration stay
as deployed. It is published as `repo.cylo.net/ubuntulemp2:3.0-1` (a new immutable tag).

## 1. Is the patched PHP available?

Ubuntu has published a php8.3 newer than `8.3.6-0ubuntu0.24.04.12` to noble-security
(check the USN at https://ubuntu.com/security/notices?q=php8.3):

```sh
curl -s 'https://api.launchpad.net/1.0/ubuntu/+archive/primary?ws.op=getPublishedSources&source_name=php8.3&exact_match=true&distro_series=https://api.launchpad.net/1.0/ubuntu/noble&pocket=Security&status=Published' \
  | jq -r '.entries[].source_package_version'
curl -s http://security.ubuntu.com/ubuntu/dists/noble-security/universe/binary-amd64/Packages.gz \
  | gzip -dc | grep -A8 '^Package: php8.3-fpm$' | grep '^Version'
```

Ubuntu published php8.3 `8.3.6-0ubuntu0.24.04.13` for CVE-2026-109618 and
CVE-2026-109619; the Dockerfile and `GATE_PHP_PATCHED_MIN` in gate.conf
require it. Use the version the USN names (it must be greater than `8.3.6-0ubuntu0.24.04.12`) as
PHP_MIN_VERSION. The binaries reach security.ubuntu.com a little after the
source is published; the second command shows when they are there.

## 2-5. Pin, build, gate, push

```sh
cd <checkout of php-multipart-fix>          # e.g. git worktree add ... origin/php-multipart-fix
git pull --ff-only
V='<patched version>'
sed -i '' "s/^ARG PHP_MIN_VERSION=.*/ARG PHP_MIN_VERSION=$V/" releases/ubuntulemp2-3.0-1/Dockerfile
git commit -am "ubuntulemp2 3.0-1: require $V"
git push origin php-multipart-fix
releases/ubuntulemp2-3.0-1/release/builder-release.sh release
```

`builder-release.sh` refuses uncommitted or unpushed work, archives this
directory from the pushed commit, builds on the Appbox builder
(appbox@builder1.builder.appboxes.co, port 10112) with `--no-cache` and
`--platform linux/amd64`, runs `release/verify-image.sh` and pushes only if
the gate passes, then prints the pushed digest. `builder-release.sh trial`
does the same as a local `local/<image>-trial:<tag>` image with the trial
build arguments in `release/gate.conf` and never pushes.

## The gate (release/verify-image.sh)

- the image is the base plus the overlay layers, with the same entrypoint,
  command, environment, ports and volumes, and (where set) base layers that
  hash to `GATE_BASE_LAYERS_SHA256`;
- every package built from the PHP source package was upgraded, to at least
  the pinned version, and newer than the last unpatched version; no other
  package was removed;
- CLI and FPM module lists, `php-fpm -t`, and every file under the packaged
  configuration and script directories match the base (only PHP's own ini
  defaults may change content);
- a multipart upload works through the CLI server;
- the deployed image and the candidate run like the platform runs them
  (init, the app's volumes): after an update the candidate serves the
  existing PHP site through its own web server and SAPI with the same
  modules, accepts a multipart upload, passes its config tests, and leaves the
  config volume exactly as recreating the deployed image does; a fresh install
  works too (and its database starts, where the app has one);
- `release/regression/*.sh` pass;
- the registry reports the tag absent (authenticated, fails closed).
