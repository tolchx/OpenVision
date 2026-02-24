
content = File.read('c:/Users/tolch/Documents/AI_Code/OpenVision/OpenVision/Views/VoiceAgent/VoiceAgentView.swift')
depth = 0
in_string = false
in_multiline_comment = false
in_single_line_comment = false

content.each_char.with_index do |char, i|
  # String detection (simplified)
  if char == '"' && !in_multiline_comment && !in_single_line_comment
    in_string = !in_string
    next
  end
  next if in_string
  
  # Comment detection
  if !in_multiline_comment && !in_single_line_comment
    if char == '/' && content[i+1] == '/'
      in_single_line_comment = true
      next
    elsif char == '/' && content[i+1] == '*'
      in_multiline_comment = true
      next
    end
  end
  
  if in_single_line_comment && char == "\n"
    in_single_line_comment = false
    next
  end
  
  if in_multiline_comment && char == '*' && content[i+1] == '/'
    in_multiline_comment = false
    # Skip the /
    next # We'll skip the next char in the next iteration? No, this is each_char.
    # Need to skip the next char... but char iteration is hard to jump.
  end
  
  next if in_multiline_comment || in_single_line_comment
  
  if char == '{'
    depth += 1
  elsif char == '}'
    depth -= 1
    if depth < 0
      puts "Unbalanced } at index #{i}"
    end
  end
end

puts "Final semantic depth: #{depth}"
