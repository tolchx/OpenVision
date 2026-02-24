$content = Get-Content 'c:\Users\tolch\Documents\AI_Code\OpenVision\OpenVision\Views\VoiceAgent\VoiceAgentView.swift'
$depth = 0
for ($i = 0; $i -lt $content.Count; $i++) {
    $line = $content[$i]
    $opens = [regex]::Matches($line, "{").Count
    $closes = [regex]::Matches($line, "}").Count
    
    $oldDepth = $depth
    $depth += ($opens - $closes)
    
    # Print lines in the body range
    if (($i + 1) -ge 100 -and ($i + 1) -le 250) {
        Write-Output "$($i + 1): ($oldDepth -> $depth): $line"
    }
}
