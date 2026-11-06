# PSScriptAnalyzer for every repo's PowerShell: its default rules, and the one-true-brace
# formatting the scripts are written in (its CodeFormattingOTBS preset). Seeded from the
# file Kindred Nights, Home Library and Marxbot already shared. Point -Settings here:
#
#   Invoke-ScriptAnalyzer -Path scripts/deploy.ps1 -Settings shared/lint/pwsh/PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @(
        # The scripts tell whoever runs them what they are doing. Since PowerShell 5,
        # Write-Host writes to the information stream, which can be captured or silenced,
        # so the rule's reason does not hold for a script run by hand.
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            IndentationSize     = 4
        }
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSUseCorrectCasing         = @{
            Enable = $true
        }
    }
}
