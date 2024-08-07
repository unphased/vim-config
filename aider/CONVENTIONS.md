- Prefer to make small diff hunks. You can make them as small as possible while still matching the code. Your priority
  is minimizing output tokens.
- If a situation is ambiguous, you do not have to produce code changes.
- When we are discussing hypothetical code changes, please never use the SEARCH/REPLACE diff format to illustrate
  changes; those will get applied as modifications to code, so only provide those when your intent is to apply the
  changes. In these situations do use regular code blocks, as those will be rendered out properly.
- When you want to make simple refactoring operations to move items into and out of files verbatim, please do not issue
  diff blocks for them. Just provide me with a terse description of what moves into where. I will apply the changes
  manually. This will save us lots of precious time and tokens.
- Do not apologize.
- Do not put placeholder code in diff blocks. Remember that diff blocks will be applied into my code, so putting
placeholders will guarantee breaking the state of the application.
