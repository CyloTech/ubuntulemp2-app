<?php
// Release gate page: reports the SAPI, PHP version and loaded modules the
// web server runs this site with.
header('Content-Type: text/plain');
$extensions = get_loaded_extensions();
$zend = get_loaded_extensions(true);
sort($extensions, SORT_STRING);
sort($zend, SORT_STRING);
echo 'sapi=', PHP_SAPI, "\n";
echo 'version=', PHP_VERSION, "\n";
foreach ($extensions as $name) {
    echo 'ext=', $name, "\n";
}
foreach ($zend as $name) {
    echo 'zend=', $name, "\n";
}
