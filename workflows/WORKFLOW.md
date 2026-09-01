---
config:
  vendor: github
  id: humdrum00001010/symphony
  states:
    - Open
  terminal_states:
    - Closed
  workspace: ~/.symphony/
mount: git clone --depth 1 https://github.com/humdrum00001010/symphony
terminate: rm -rf $workspace
spawn: codex app-server --config 'model="gpt-5.6"' --config model_reasoning_effort=xhigh
---

prompts...
