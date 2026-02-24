$content = Get-Content 'c:\Users\tolch\Documents\AI_Code\OpenVision\OpenVision\Views\VoiceAgent\VoiceAgentView.swift'
$depth = 0
for ($i = 0; $i -lt $content.Count; $i++) {
    $line = $content[$i]
    $opens = [regex]::Matches($line, "{").Count
    $closes = [regex]::Matches($line, "}").Count
    
    # Check if a close happens before an open on the same line?
    # Usually closes happen first in a line like "} else {"
    $delta = $opens - $closes
    $oldDepth = $depth
    $depth += $delta
    
    # Print any line containing 'private'
    if ($line.Contains("private")) {
        Write-Output "$($i + 1): ($depth) $line"
    }
}
