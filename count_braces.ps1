$content = Get-Content 'c:\Users\tolch\Documents\AI_Code\OpenVision\OpenVision\Views\VoiceAgent\VoiceAgentView.swift' -Raw
$openBraces = [regex]::Matches($content, "{").Count
$closeBraces = [regex]::Matches($content, "}").Count
Write-Host "Open: $openBraces"
Write-Host "Close: $closeBraces"
Write-Host "Balance: $($openBraces - $closeBraces)"
