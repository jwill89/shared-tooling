<?php

declare(strict_types=1);

use Rector\Config\RectorConfig;
use Rector\Set\ValueObject\SetList;

/**
 * The shared Rector set: strip dead code. Every PHP project runs it today. The
 * project adds its paths and the PHP set for the version its composer.json requires,
 * so Rector never rewrites to syntax the server can't run:
 *
 *     return RectorConfig::configure()
 *         ->withPaths([__DIR__ . '/src'])
 *         ->withSets([__DIR__ . '/../shared/lint/php/rector-set.php'])
 *         ->withPhpSets(php85: true);
 */
return static function (RectorConfig $rectorConfig): void {
    $rectorConfig->sets([SetList::DEAD_CODE]);
};
