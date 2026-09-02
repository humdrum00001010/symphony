---
config:
  vendor: github
  id: humdrum00001010/symphony
  states:
    - OPEN
  terminal_states:
    - CLOSED
  workspace: ./.symphony/
mount: git clone --depth 1 https://github.com/humdrum00001010/symphony
terminate: rm -rf $workspace
agent:
  vendor: codex
  model: gpt-5.6-sol
  reasoning: high
---

Make empty PR corresponding the issue you received.

Append comment on the issue with "∎" when you are done.
