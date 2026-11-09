# Reasoning effort

LM Studio's built-in **Reasoning** dropdown (the `Reasoning >` row in Model
Parameters) drives reasoning effort for the fake loaded model. The shim
forwards it to Strata's gateway as the OpenAI `reasoning_effort` field (verified
that `low` → shorter reasoning, `high` → longer).

The dropdown only renders once LM Studio detects the model's **reasoning
capability** (a metadata badge). The badge is filled by a `chat_template` that
references `enable_thinking` — see [badges.md](badges.md). Once it renders, LM
Studio sends `reasoning_effort` per request.

## Manual default (before the badge renders)

When a request carries no effort, the shim applies a manual default. Precedence:

1. A per-request `reasoning_effort` from LM Studio (once the badge renders).
2. `STRATA_REASONING_EFFORT` env (set by the install script / your shell).
3. The config file `~/.lmstudio/strata-shim.conf` — a `KEY = VALUE` file.
4. Otherwise: omit the field (Strata's own default).

Valid values: `off` `none` `low` `medium` `high` `max`.

### Set it in the config file

Edit `~/.lmstudio/strata-shim.conf` (the shim reads it at each launch; it never
writes it):

```ini
# Reasoning effort forwarded to Strata when LM Studio does not send one.
# off|none|low|medium|high|max
reasoning_effort = low
```

Or set the env instead (wins over the file):

```bash
export STRATA_REASONING_EFFORT=high
```

The shim logs the applied value: `reasoning_effort -> gateway: low (manual
default)`.

## Thinking budget

Through the gateway only `reasoning_effort` is honoured. Strata's own GUI
exposes a Thinking budget too, but that applies to Strata's native chat, not
to the gateway the shim dials — there is no gateway equivalent, so thinking
budget is a capability gap on this path.
