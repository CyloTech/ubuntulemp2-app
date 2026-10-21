# Regression checks

Each `*.sh` file here runs inside the candidate image during the release gate
(`sh /gate/regression/<name>.sh`, with this release directory mounted
read-only at `/gate` and the PHP binary name in `$GATE_PHP`, for example
`php8.3`). It must exit 0 only when the issue it covers is fixed.

When the details of the 21 October 2026 multipart/form-data fixes are public,
add a check that sends the problematic request to `$GATE_PHP -S` and asserts
the patched behaviour. The gate already runs a normal multipart upload through
the CLI server and through the image's own web server.
