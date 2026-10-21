<?php
// HTTP checks for the release gate. Runs inside the container under test,
// reading this script from stdin:
//
//   php8.3 -- probe  <port>   prints the status of GET / (any status = up)
//   php8.3 -- info   <port>   prints the status and body of /gate-info.php
//   php8.3 -- upload <port>   POSTs multipart form data to /gate-upload.php
//                             and exits 0 only when PHP parsed it correctly
//
// Raw sockets are used so the check does not depend on allow_url_fopen or
// on curl being installed in the image.

error_reporting(E_ALL);
$mode = isset($argv[1]) ? $argv[1] : '';
$port = isset($argv[2]) ? (int) $argv[2] : 80;

function gate_request($port, $method, $path, array $headers, $body)
{
    $fp = @fsockopen('127.0.0.1', $port, $errno, $errstr, 5);
    if (!$fp) {
        return array(0, "connect failed: $errstr");
    }
    stream_set_timeout($fp, 60);
    $out = "$method $path HTTP/1.0\r\nHost: localhost\r\nUser-Agent: cylo-release-gate\r\n";
    foreach ($headers as $header) {
        $out .= $header . "\r\n";
    }
    if ($body !== null) {
        $out .= 'Content-Length: ' . strlen($body) . "\r\n";
    }
    $out .= "\r\n";
    if ($body !== null) {
        $out .= $body;
    }
    fwrite($fp, $out);
    $response = stream_get_contents($fp);
    fclose($fp);
    if ($response === false || $response === '') {
        return array(0, 'empty response');
    }
    $parts = explode("\r\n\r\n", $response, 2);
    if (!preg_match('#^HTTP/\d\.\d (\d{3})#', $parts[0], $m)) {
        return array(0, 'unexpected status line: ' . substr($parts[0], 0, 80));
    }
    return array((int) $m[1], isset($parts[1]) ? $parts[1] : '');
}

if ($mode === 'probe') {
    list($status, $body) = gate_request($port, 'GET', '/gate-ready-probe', array(), null);
    echo $status, "\n";
    exit($status > 0 ? 0 : 1);
}

if ($mode === 'info') {
    list($status, $body) = gate_request($port, 'GET', '/gate-info.php', array(), null);
    echo "status=$status\n", $body;
    exit($status === 200 ? 0 : 1);
}

if ($mode === 'upload') {
    $small = "hello";
    $large = str_repeat("0123456789abcdef", 8192);
    $boundary = 'gate' . md5(uniqid('', true));
    $parts = array(
        array('a', null, 'b'),
        array('arr[]', null, '1'),
        array('arr[]', null, '2'),
        array('f', 'small.txt', $small),
        array('g', 'large.bin', $large),
    );
    $body = '';
    foreach ($parts as $part) {
        $body .= "--$boundary\r\n";
        if ($part[1] === null) {
            $body .= "Content-Disposition: form-data; name=\"{$part[0]}\"\r\n\r\n";
        } else {
            $body .= "Content-Disposition: form-data; name=\"{$part[0]}\"; filename=\"{$part[1]}\"\r\n";
            $body .= "Content-Type: application/octet-stream\r\n\r\n";
        }
        $body .= $part[2] . "\r\n";
    }
    $body .= "--$boundary--\r\n";
    list($status, $response) = gate_request(
        $port,
        'POST',
        '/gate-upload.php',
        array("Content-Type: multipart/form-data; boundary=$boundary"),
        $body
    );
    $expected = json_encode(array(
        'files' => 2,
        'f' => array(0, strlen($small), md5($small), 'small.txt'),
        'g' => array(0, strlen($large), md5($large), 'large.bin'),
        'a' => 'b',
        'arr' => array('1', '2'),
    ));
    $response = trim($response);
    echo "status=$status\n";
    echo "response=$response\n";
    if ($status !== 200 || $response !== $expected) {
        echo "expected=$expected\n";
        exit(1);
    }
    echo "multipart upload ok\n";
    exit(0);
}

fwrite(STDERR, "usage: php -- probe|info|upload <port>\n");
exit(2);
