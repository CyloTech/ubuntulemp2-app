# ubuntulemp2 3.0-1 (Lemp Stack): the current ubuntulemp2 3.0 image (Ubuntu
# 24.04 baseimage build of 2025-12-08, php8.3 from the Ubuntu archive, nginx +
# php-fpm, MySQL installed by the first-run installer) with only the binaries
# built from the php8.3 source package upgraded. Everything else is unchanged.
#
# Before a release build set PHP_MIN_VERSION to the patched php8.3 version
# from Ubuntu's security notice; the build fails while it is UNSET.
FROM repo.cylo.net/ubuntulemp2@sha256:3897de3627f7b2d6eb5397eb0c73e6cb5ff1b58a402dfcb713449a333bee2acc

ARG PHP_SOURCE_PACKAGE=php8.3
ARG PHP_MIN_VERSION=8.3.6-0ubuntu0.24.04.13
LABEL net.cylo.php-source-package="${PHP_SOURCE_PACKAGE}" \
      net.cylo.php-min-version="${PHP_MIN_VERSION}"

RUN set -eu; \
    [ "$PHP_MIN_VERSION" != UNSET ] || { echo "Set PHP_MIN_VERSION to the patched $PHP_SOURCE_PACKAGE version" >&2; exit 1; }; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    pkgs=$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}\n' \
        | awk -F'|' -v src="$PHP_SOURCE_PACKAGE" '$1 ~ /^ii/ && $3 == src {print $2}'); \
    [ -n "$pkgs" ]; \
    apt-get install -y --only-upgrade --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs; \
    for pkg in $pkgs; do \
        version=$(dpkg-query -W -f='${Version}' "$pkg"); \
        dpkg --compare-versions "$version" ge "$PHP_MIN_VERSION" \
            || { echo "$pkg $version is older than $PHP_MIN_VERSION" >&2; exit 1; }; \
    done; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    php-fpm8.3 -t
