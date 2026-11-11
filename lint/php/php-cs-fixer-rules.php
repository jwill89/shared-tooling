<?php

declare(strict_types=1);

/**
 * The shared PHP CS Fixer rules: PER Coding Style 3.0, PSR-12's successor, pinned so
 * a fixer upgrade can't move the standard. The project adds the migration set for the
 * PHP its composer.json requires, so the fixer never writes syntax the server can't run:
 *
 *     ->setRules([
 *         ...require __DIR__ . '/shared/lint/php/php-cs-fixer-rules.php',
 *         '@PHP8x1Migration' => true,
 *     ])
 *
 * @return array<string, mixed>
 */
return [
    '@PER-CS3x0' => true,
    // Multi-line arrays and parameter lists end with a comma; call arguments don't.
    'trailing_comma_in_multiline' => ['elements' => ['arrays', 'array_destructuring', 'match', 'parameters']],
    'no_unused_imports' => true,
];
