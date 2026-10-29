<#
.SYNOPSIS
    Creates or updates one marked comment on a pull request.

.DESCRIPTION
    The comment is identified by the first line of its body, an HTML comment
    such as <!-- pr-deployment:core -->. When a comment with that marker
    already exists it is edited in place, so every push updates the same
    what-if comment instead of adding a new one. Uses the GitHub CLI, which
    reads GH_TOKEN.

.PARAMETER Repository
    owner/name of the repository.

.PARAMETER PullRequest
    The pull request number.

.PARAMETER BodyPath
    File holding the comment body. Its first line must be the marker.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [ValidateRange(1, [int]::MaxValue)] [int] $PullRequest,
    [Parameter(Mandatory)] [string] $BodyPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $BodyPath).Path)
$marker = ($body -split "`r?`n", 2)[0].Trim()
if ($marker -cnotmatch '^<!-- [a-z0-9:_-]+ -->$') {
    throw "The comment body must start with a marker line such as <!-- pr-deployment:core -->; found '$marker'."
}

$pages = & gh api --paginate "repos/$Repository/issues/$PullRequest/comments" --jq '.[] | {id: .id, body: .body}'
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list the comments of pull request #$PullRequest."
}
$existing = @($pages | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { ([string] $_.body).StartsWith($marker, [StringComparison]::Ordinal) })

$payload = Join-Path ([IO.Path]::GetTempPath()) ("comment-$([guid]::NewGuid().ToString('N')).json")
try {
    [IO.File]::WriteAllText($payload, (@{ body = $body } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    if ($existing.Count -gt 0) {
        $id = $existing[0].id
        & gh api --method PATCH "repos/$Repository/issues/comments/$id" --input $payload | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to update comment $id." }
        Write-Output "Updated comment $id on pull request #$PullRequest."
    }
    else {
        & gh api --method POST "repos/$Repository/issues/$PullRequest/comments" --input $payload | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to comment on pull request #$PullRequest." }
        Write-Output "Commented on pull request #$PullRequest."
    }
}
finally {
    Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue
}
