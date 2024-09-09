; extends

(
  (script_element
    (start_tag
      (attribute
        (attribute_name) @_attr-name
        (quoted_attribute_value
          (attribute_value) @_attr-value
        )
      )
    )
    (raw_text) @injection.content
  )
  (#eq? @_attr-name "type")
  (#match? @_attr-value "x-shader")
  (#set! injection.language "glsl")
)
