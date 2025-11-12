; extends
(
  [
    (variable_declarator
      (comment) @c
      value: (template_string (string_fragment)? @injection.content))
    (pair
      (comment) @c
      value: (template_string (string_fragment)? @injection.content))
  ]
  (#match? @c "^(/\\*\\s*wgsl\\s*\\*/|//\\s*wgsl\\s*)$")
  (#set! injection.language "wgsl")
)
