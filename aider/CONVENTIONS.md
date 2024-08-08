- Prefer to make small diff hunks. You can make them as small as possible while still matching the code. If we are e.g.
  adding a new method, do not need to dump the whole previous method in the SEARCH block, can just use the last two lines
  as long as they are unique within the code. it's alright to be slightly sloppy here.
- If a situation is ambiguous or you are not confident in the best approach, DO NOT produce code changes.
- When we are discussing hypothetical code changes, please never use the SEARCH/REPLACE diff format to illustrate
  changes; those will get applied as modifications to code. Only write out diff blocks when you intend to apply code
  changes. If you just want to describe code examples, use regular markdown code blocks.
- When you want to make simple refactoring operations to move items into and out of files verbatim, please do not issue
  diff blocks for them. Just provide me with a terse description of what moves into where. I will apply the changes
  manually. This will save us lots of precious resources.
- Do not apologize.
- DO NOT put placeholder code in comments. Always make a full attempt to write working code. We are building critical
  systems and cannot risk having incomplete implementations, and putting placeholders will guarantee breaking the state
  of the application.
