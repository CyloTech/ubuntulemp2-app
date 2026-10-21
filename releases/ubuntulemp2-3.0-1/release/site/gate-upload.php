<?php
// Release gate page: echoes what PHP parsed from a multipart/form-data POST.
header('Content-Type: text/plain');
function gate_file($name)
{
    if (!isset($_FILES[$name])) {
        return null;
    }
    $file = $_FILES[$name];
    $hash = is_uploaded_file($file['tmp_name']) ? md5_file($file['tmp_name']) : null;
    return array($file['error'], $file['size'], $hash, $file['name']);
}
echo json_encode(array(
    'files' => count($_FILES),
    'f' => gate_file('f'),
    'g' => gate_file('g'),
    'a' => isset($_POST['a']) ? $_POST['a'] : null,
    'arr' => isset($_POST['arr']) ? $_POST['arr'] : null,
));
