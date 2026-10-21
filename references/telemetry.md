# Vendor telemetry of the serving stacks

Several serving stacks report to their vendor by default: usage statistics at start
and on a timer, analytics events, update checks. A stack this skill brings up has all
of it off, also where the image already defaults it, so the compose file shows the
switch. Monitoring the operator runs (Prometheus exporters, a metrics agent) is not
vendor telemetry and stays.

## Switches

| Component | Switches | What they stop |
|---|---|---|
| vLLM (CUDA, XPU, `llm-scaler`) | `VLLM_NO_USAGE_STATS=1`, `DO_NOT_TRACK=1` | a report to `stats.vllm.ai` at start (CPU and GPU model, memory, model architecture, quantization, context length, engine flags) and a heartbeat every 10 minutes |
| Hugging Face Hub, transformers, sentence-transformers | `HF_HUB_DISABLE_TELEMETRY=1`; `DO_NOT_TRACK=1` works too | telemetry requests to `huggingface.co` |
| Infinity | `INFINITY_ANONYMOUS_USAGE_STATS=0`, `DO_NOT_TRACK=1` | PostHog events to `eu.i.posthog.com` |
| OpenWebUI | `SCARF_NO_ANALYTICS=true`, `DO_NOT_TRACK=true`, `ANONYMIZED_TELEMETRY=false`, `ENABLE_VERSION_UPDATE_CHECK=false` | Scarf and Chroma analytics (the image defaults the first three), the release check against `api.github.com` |
| Gradio, inside a speech or UI image | `GRADIO_ANALYTICS_ENABLED=False`; Gradio ignores `DO_NOT_TRACK` | analytics and version checks to `api.gradio.app` |
| Ray, when an engine starts it | `RAY_USAGE_STATS_ENABLED=0` | usage statistics to `usage-stats.ray.io` |

vLLM compares both variables with the string `1`: `DO_NOT_TRACK=true` leaves its reports
on. Write `"1"` in compose, quoted, so YAML keeps it a string.

Nothing to switch off: TEI 1.9 (its binary was read in 2026-10; it exports OTLP traces
only when `--otlp-endpoint` is set), and llama.cpp, whisper.cpp and Ollama, which carry
no usage reporting of their own per their documentation. OpenVINO Model Server was not
audited: read its documentation and image for telemetry before it goes live, and add
what you find to this table. The same goes for any other component.

## A running engine started without the switches

vLLM also reads `~/.config/vllm/do_not_track` once at start. For an engine that cannot
be recreated now:

```bash
docker exec <container> touch /root/.config/vllm/do_not_track
docker restart <container>      # the file survives a restart, not a recreation
```

Then put the switches into whatever recreates the container (compose file, run
script, spec), or the next recreation reports again.

## Checking

- `bash scripts/check.sh` fails every running vLLM, Infinity and OpenWebUI container
  without its switches and warns about a vLLM engine that is silent only through the
  `do_not_track` file;
- `docker inspect` of a container: print only the switch names above, never the whole
  environment, it carries keys;
- a vLLM container with `/root/.config/vllm/usage_stats.json` has reported: vLLM
  appends a copy of every report there before it sends it;
- a second layer, if the operator wants one, is a DNS block on the host for the names
  above (`stats.vllm.ai`, `posthog.com`, `api.gradio.app`, `usage-stats.ray.io`).
  Block by name: these endpoints sit behind CDN addresses shared with other sites.
  `huggingface.co` cannot be blocked where models are downloaded, its switch is the
  only control.
