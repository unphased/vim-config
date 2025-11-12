; extends

; WGSL
(
  [
    (variable_declarator (comment) @c value: (template_string (string_fragment)? @injection.content))
    (assignment_expression (comment) @c right: (template_string (string_fragment)? @injection.content))
    (arguments (comment) @c (template_string (string_fragment)? @injection.content))
    (pair (comment) @c value: (template_string (string_fragment)? @injection.content))
  ]
  (#match? @c "^(/\\*\\s*wgsl\\s*\\*/|//\\s*wgsl\\s*)$")
  (#set! injection.language "wgsl")
)

; GLSL
(
  [
    (variable_declarator (comment) @c value: (template_string (string_fragment)? @injection.content))
    (assignment_expression (comment) @c right: (template_string (string_fragment)? @injection.content))
    (arguments (comment) @c (template_string (string_fragment)? @injection.content))
    (pair (comment) @c value: (template_string (string_fragment)? @injection.content))
  ]
  (#match? @c "^(/\\*\\s*glsl\\s*\\*/|//\\s*glsl\\s*)$")
  (#set! injection.language "glsl")
)
