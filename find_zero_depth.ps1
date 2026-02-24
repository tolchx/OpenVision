$file = "c:\Users\tolch\Documents\AI_Code\OpenVision\OpenVision\Views\VoiceAgent\VoiceAgentView.swift"
$lines = Get-Content $file

$depth = 0
$in_string = $false
$in_multiline_comment = $false
$in_single_line_comment = $false

for ($lineIdx = 0; $lineIdx -lt $lines.Count; $lineIdx++) {
    $line = $lines[$lineIdx]
    $lineChars = $line.ToCharArray()
    
    for ($i = 0; $i -lt $lineChars.Count; $i++) {
        $char = $lineChars[$i]
        $nextChar = if ($i + 1 -lt $lineChars.Count) { $lineChars[$i + 1] } else { $null }

        if ($char -eq '"' -and -not $in_multiline_comment -and -not $in_single_line_comment) {
            $in_string = -not $in_string
        }
        if ($in_string) { continue }

        if (-not $in_multiline_comment -and -not $in_single_line_comment) {
            if ($char -eq '/' -and $nextChar -eq '/') {
                $in_single_line_comment = $true
            }
            if ($char -eq '/' -and $nextChar -eq '*') {
                $in_multiline_comment = $true
            }
        }

        if ($in_multiline_comment -and $char -eq '*' -and $nextChar -eq '/') {
            $in_multiline_comment = $false
        }

        if ($in_multiline_comment -or $in_single_line_comment) { continue }

        if ($char -eq '{') {
            $depth++
        }
        elseif ($char -eq '}') {
            $depth--
        }
    }
    
    $in_single_line_comment = $false

    if ($depth -eq 0 -and ($lineIdx + 1) -gt 10 -and ($lineIdx + 1) -lt 1765) {
        Write-Output "ZERO DEPTH at line $($lineIdx + 1): $line"
    }
}
Write-Output "Final Depth: $depth"
