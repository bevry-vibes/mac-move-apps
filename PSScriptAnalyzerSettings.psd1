# PSScriptAnalyzer settings for this repository.
# PSAvoidUsingWriteHost is excluded repo-wide: this is an interactive host-UI tool -
# styled console output via Write-Host is the intended mechanism.
# PSReviewUnusedParameter is excluded repo-wide: the script-level command params are
# consumed inside the command functions after the dispatch switch, which the rule cannot see.
# Lint with:  Invoke-ScriptAnalyzer -Path . -Settings ./PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @('PSAvoidUsingWriteHost', 'PSReviewUnusedParameter')
}