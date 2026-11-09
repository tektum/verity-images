<?php
// Minimal FastCGI client: sends one request to PHP-FPM and prints the raw CGI
// response (headers and body) on stdout and FastCGI stderr on stderr.
// Usage: php fcgi.php HOST PORT METHOD PATH QUERY_STRING [BODY]
// A PATH ending in / is served by its index.php, as a front web server would.
declare(strict_types=1);

if ($argc < 6) {
    fwrite(STDERR, "usage: fcgi.php HOST PORT METHOD PATH QUERY_STRING [BODY]\n");
    exit(2);
}
[, $host, $port, $method, $path, $query] = $argv;
$script = str_ends_with($path, '/') ? "{$path}index.php" : $path;
$body = $argv[6] ?? '';

function record(int $type, string $content): string
{
    return pack('CCnnCx', 1, $type, 1, strlen($content), 0) . $content;
}

function pair(string $name, string $value): string
{
    $length = static fn (int $n): string => $n < 128 ? chr($n) : pack('N', $n | 0x80000000);
    return $length(strlen($name)) . $length(strlen($value)) . $name . $value;
}

function read_exact($socket, int $length): string
{
    $data = '';
    while (strlen($data) < $length) {
        $chunk = fread($socket, $length - strlen($data));
        if ($chunk === false || $chunk === '') {
            $meta = stream_get_meta_data($socket);
            if ($meta['timed_out'] || feof($socket)) {
                fwrite(STDERR, "FastCGI connection closed before END_REQUEST\n");
                exit(3);
            }
            continue;
        }
        $data .= $chunk;
    }
    return $data;
}

$socket = stream_socket_client("tcp://$host:$port", $errno, $error, 10);
if ($socket === false) {
    fwrite(STDERR, "cannot connect to $host:$port: $error\n");
    exit(4);
}
stream_set_timeout($socket, 120);

$uri = $query === '' ? $path : "$path?$query";
$params = [
    'GATEWAY_INTERFACE' => 'CGI/1.1',
    'SERVER_SOFTWARE' => 'verity-smoke',
    'REQUEST_METHOD' => $method,
    'SCRIPT_FILENAME' => "/var/www/html$script",
    'SCRIPT_NAME' => $script,
    'PHP_SELF' => $script,
    'DOCUMENT_URI' => $script,
    'DOCUMENT_ROOT' => '/var/www/html',
    'REQUEST_URI' => $uri,
    'QUERY_STRING' => $query,
    'SERVER_NAME' => 'wordpress.test',
    'SERVER_PORT' => '80',
    'SERVER_PROTOCOL' => 'HTTP/1.1',
    'HTTP_HOST' => 'wordpress.test',
    'REMOTE_ADDR' => '127.0.0.1',
    'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
    'CONTENT_LENGTH' => (string) strlen($body),
];
$encoded = '';
foreach ($params as $name => $value) {
    $encoded .= pair($name, $value);
}

// FCGI_BEGIN_REQUEST (role FCGI_RESPONDER), FCGI_PARAMS, FCGI_STDIN.
$request = record(1, pack('nCx5', 1, 0)) . record(4, $encoded) . record(4, '');
if ($body !== '') {
    $request .= record(5, $body);
}
$request .= record(5, '');
fwrite($socket, $request);

$stdout = '';
$stderr = '';
while (true) {
    $header = unpack('Cversion/Ctype/nid/nlength/Cpadding/Creserved', read_exact($socket, 8));
    $content = $header['length'] > 0 ? read_exact($socket, $header['length']) : '';
    if ($header['padding'] > 0) {
        read_exact($socket, $header['padding']);
    }
    if ($header['type'] === 6) {
        $stdout .= $content;
    } elseif ($header['type'] === 7) {
        $stderr .= $content;
    } elseif ($header['type'] === 3) {
        break;
    }
}
fwrite(STDERR, $stderr);
echo $stdout;
