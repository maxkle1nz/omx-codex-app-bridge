---
name: omx-codex-app-bridge
description: Use when the user wants to integrate oh-my-codex (OMX) with Codex App or plain Codex sessions safely, launch real OMX from the shell, keep setup project-local under .codex and .omx, and avoid unsupported behavior from pretending OMX runtime workflows are active inside the app.
---

# OMX Codex App Bridge

Use this skill when the user wants real `oh-my-codex` behavior from a Codex App session without relying on global installation or pretending the App is already inside the OMX runtime.

## Core contract

- Treat `autopilot`, `ralph`, `ultrawork`, `ultraqa`, `team`, `swarm`, and similar OMX runtime keywords as **runtime-only**.
- In Codex App or plain Codex sessions without actual OMX runtime state, do **not** act as if those workflows are active just because the words appeared.
- When the user wants an App-safe equivalent, keep working with native Codex surfaces such as planning, clarification, or native subagents.
- When the user explicitly wants real OMX behavior, launch upstream OMX from the shell with the bundled wrapper.

This matches the upstream OMX guidance: App-safe by default, shell-launched runtime when explicitly requested.

## Safety rules

- Keep all runtime state project-local.
- Use the current workspace as the target project unless the user explicitly asks for another path.
- Do not install OMX globally with `npm -g`.
- Do not copy or sync `~/.codex/auth.json`, `~/.codex/config.toml`, or any other global Codex files into the project.
- Use project-local Codex auth under `./.codex/`.
- Build the upstream OMX checkout with `npm install --ignore-scripts` to avoid upstream `postinstall` surprises.
- Do not default to `--madmax`; dangerous upstream launch modes must be explicit.
- Explain that project-local `CODEX_HOME` isolates auth/config/state, but does not sandbox machine access by itself.

## Paths

The wrapper uses these project-local paths:

- `./.codex/` for the Codex home used by OMX
- `./.omx/` for upstream OMX runtime state
- `./.omx-codex-app-bridge/` for the local upstream checkout and bridge logs

## Wrapper script

Do not assume `scripts/omx-bridge.sh` exists inside the user's repository. The wrapper lives inside the installed skill directory.

Resolve it like this:

```bash
BRIDGE_SCRIPT="${CODEX_HOME:-$HOME/.codex}/skills/omx-codex-app-bridge/scripts/omx-bridge.sh"
```

Run the wrapper at:

`$BRIDGE_SCRIPT`

Common commands:

```bash
bash "$BRIDGE_SCRIPT" bootstrap
bash "$BRIDGE_SCRIPT" setup
bash "$BRIDGE_SCRIPT" codex-login-status
bash "$BRIDGE_SCRIPT" codex-login-device
OPENAI_API_KEY=... bash "$BRIDGE_SCRIPT" codex-login-api-key
bash "$BRIDGE_SCRIPT" doctor
bash "$BRIDGE_SCRIPT" launch
bash "$BRIDGE_SCRIPT" launch-dangerous
bash "$BRIDGE_SCRIPT" exec --skip-git-repo-check -C . "Reply with exactly OMX-EXEC-OK"
bash "$BRIDGE_SCRIPT" omx team 3:executor "fix the failing tests"
```

## Recommended workflow

1. If the user only wants an App-safe equivalent of an OMX concept, stay in the App and explain the runtime boundary briefly.
2. If the user wants actual OMX runtime behavior:
   - run `bootstrap`
   - run `setup`
   - verify local auth with `codex-login-status`
   - if needed, run `codex-login-device` or `codex-login-api-key`
   - run `doctor`
   - then run `launch`, `exec`, `question`, or `omx ...`
3. Only use `launch-dangerous` when the user explicitly wants the upstream dangerous launch path that bypasses Codex approvals and sandboxing.
4. Prefer `exec`, `question`, and `launch` wrappers over manually reconstructing the upstream command line.

## Auth behavior

- `launch`, `exec`, and `question` require project-local Codex auth in `./.codex/`.
- If local auth is missing, stop and point the user to:
  - `bash "$BRIDGE_SCRIPT" codex-login-device`
  - `OPENAI_API_KEY=... bash "$BRIDGE_SCRIPT" codex-login-api-key`
- Do not fall back to global auth implicitly.
- `codex-login-api-key` requires a real OpenAI API key. If the user's main `~/.codex` is authenticated by ChatGPT account session tokens, that does not count as an API key; use `codex-login-device` for the isolated project login instead.
- If the user asks whether this bridge is "safe", be precise: it isolates state and defaults to safer launch args, but it is not a system sandbox.

## Environment overrides

Use only when needed:

- `OMX_PROJECT_ROOT`
- `OMX_SOURCE_DIR`
- `OMX_REPO_URL`
- `OMX_REPO_REF`
- `OMX_ENTRYPOINT`
- `CODEX_BIN`
- `NODE_BIN`
- `NPM_BIN`
- `GIT_BIN`

The wrapper defaults to a tested upstream `oh-my-codex` commit pin. Only override `OMX_REPO_REF` when the user explicitly wants a different upstream revision.

## Example prompts

- `Use $omx-codex-app-bridge to bootstrap oh-my-codex here without touching my global Codex setup.`
- `Use $omx-codex-app-bridge and launch real OMX team mode from this repo.`
- `Use $omx-codex-app-bridge para subir o OMX local neste projeto e nao mexer no ~/.codex.`
- `Use $omx-codex-app-bridge para rodar o runtime real do OMX pelo shell, mas manter o App em modo seguro.`
