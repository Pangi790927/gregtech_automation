# doreq - copies a script-request to the server, runs it there, then deletes it. What it prints
# is also saved beside it, as <request>.out, for Claude to read.
#     ./doreq 001-survey.sh [arguments...]
# CLAUDE NEVER MODIFIES THIS FILE. It is the user's; Claude is not allowed to change it.
param($Request)
$c = Get-Content -Raw "$PSScriptRoot\..\config.ini" | ConvertFrom-StringData
$to = "$($c.ssh_user)@$($c.server)"
$name = Split-Path -Leaf $Request
scp $Request "${to}:$name"
ssh $to "bash $name $args 2>&1; rm $name" | Tee-Object "$PSScriptRoot\$name.out"
