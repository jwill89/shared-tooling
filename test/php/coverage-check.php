<?php

declare(strict_types=1);

/**
 * Fails the run when line or method coverage in PHPUnit's clover report falls below
 * the floor. PHPUnit (and Pest) have no threshold of their own. The floor comes from the
 * command line, so each project keeps its own in composer.json.
 *
 *     "test:coverage": [
 *         "@php -d xdebug.mode=coverage vendor/bin/phpunit --coverage-clover .phpunit.cache/clover.xml",
 *         "@php ../shared/test/php/coverage-check.php .phpunit.cache/clover.xml --lines=95 --methods=88"
 *     ]
 *
 * The floor starts a little under what the suite reaches today; raise it as tests
 * land, never lower it.
 */

// Read by hand rather than with getopt(), which stops at the report's path and would
// miss the floors after it.
$file = '';
$floor = [];
foreach (array_slice($argv, 1) as $arg) {
    if (preg_match('/^--(lines|methods)=(\d+(?:\.\d+)?)$/', $arg, $m) === 1) {
        $floor[$m[1]] = (float) $m[2];
    } elseif (!str_starts_with($arg, '--')) {
        $file = $arg;
    }
}
if ($floor === []) {
    fwrite(STDERR, "Usage: coverage-check.php <clover.xml> --lines=<percent> [--methods=<percent>]\n");
    exit(2);
}

$report = is_file($file) ? simplexml_load_file($file) : false;
if ($report === false) {
    fwrite(STDERR, "No clover report at '{$file}'.\n");
    exit(1);
}

$metrics = $report->project->metrics;
$measured = [
    'lines' => percent((int) $metrics['coveredstatements'], (int) $metrics['statements']),
    'methods' => percent((int) $metrics['coveredmethods'], (int) $metrics['methods']),
];

$failed = false;
foreach ($floor as $kind => $min) {
    $ok = $measured[$kind] >= $min;
    $failed = $failed || !$ok;
    printf("%-7s %5.1f%% (floor %4.1f%%)%s\n", $kind, $measured[$kind], $min, $ok ? '' : '  BELOW THE FLOOR');
}
exit($failed ? 1 : 0);

function percent(int $covered, int $total): float
{
    return $total === 0 ? 100.0 : 100 * $covered / $total;
}
