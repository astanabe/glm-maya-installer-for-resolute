# glm-maya-installer-for-resolute

GLM-5.3-Flash installer script for Ubuntu 26.04 LTS Resolute Raccoon (Server or Desktop), using the [Project Maya](https://github.com/mw00/project-maya) inference engine

The installer sets up Project Maya v1.1.63 and GLM-5.3-Flash as a systemd service behind nginx, for web browsers (PC and smartphone) and coding agents on an intranet. Compiling the engine, downloading the model and writing the engine configuration are left to Maya's own setup (`maya.sh`); this installer adds the CUDA toolkit and the other apt packages, the service user, the systemd unit, the nginx site, ufw rules, the selection of GPUs and network interfaces, and an uninstaller.

> **Status**: the installer `install-glm-maya.sh` is written, but it **has never been run on real hardware**: the development machine has no supported GPU. Its settings, the files it generates, its calls of Maya's setup and its nginx site were tested there with stand-ins; everything that needs root or a GPU was not. What this README says about Maya comes from reading the documentation and the source of Maya v1.1.63; see [Verification](#verification).

## Prerequisites

- Ubuntu 26.04 LTS (Resolute Raccoon), x86_64, Server or Desktop, with the `universe` and `multiverse` components enabled. Ubuntu on WSL is not supported (the installer detects it and stops).
  - On Desktop, the display also uses GPU memory, and the service stops while the machine is suspended.
- A CPU with AVX2
- Root privileges (`sudo`)
- Internet access to GitHub (Maya, llama.cpp source), Hugging Face (models), PyPI (Maya's Python packages) and the Ubuntu apt repositories
- An NVIDIA GPU of the RTX 20 series or newer (compute capability 7.5 or higher). Maya has no CPU-only engine. 12 GB of GPU memory or more is recommended. AMD GPUs and Intel Arc are not supported by this installer.
- **NVIDIA driver 580 or later, installed in advance**. The installer never installs GPU drivers. Install the driver and reboot (e.g. `sudo ubuntu-drivers install`), so that `nvidia-smi` works. The installer stops with an older driver, because the engine is compiled with CUDA 13.
- A fast NVMe SSD with room for the selected quantization, and enough memory for it (see [Quantization](#quantization)); the installer checks both and warns if they look insufficient. What the GPU memory and the RAM do not hold is read from the disk while the model answers, so a hard disk is not suitable.

The CUDA toolkit is not a prerequisite: the installer installs `cuda-toolkit-13` from the Ubuntu repository.

## Usage

```
sudo bash install-glm-maya.sh                            # interactive install
sudo bash install-glm-maya.sh \
    --destdir /opt/glm-maya --quant Maya-S ...           # non-interactive install
sudo bash install-glm-maya.sh --uninstall                # uninstall
```

- Run as root. The installer is a single file and needs nothing else from this repository.
- Every prompt has a corresponding command-line option and environment variable. Only values that are not given are asked. When standard input is not a terminal, the defaults are used without prompting.
- Values are taken in this order: command-line option, environment variable, the previous installation (`/etc/glm-maya/install.conf`), default.
- Re-running the installer updates the existing installation in place: the systemd unit, the nginx site and the other generated files are overwritten; Maya's source tree and the compiled engine are reused when the pinned version is already installed; the model files already downloaded are checked and reused by Maya; the generated API key is kept. If the quantization changed, the installer removes the engine configurations of the other quantizations and offers to delete their model files (only when run interactively).
- `--uninstall` stops and disables the service and removes the systemd unit, the nginx site configuration, `/etc/glm-maya`, the ufw rules added by the installer and destdir (with Maya and all downloaded files). apt packages (including the CUDA toolkit), nginx itself and the service user are kept.

### Options

Asked interactively when not given:

| Option | Environment variable | Default |
|---|---|---|
| `--destdir DIR` | `GLMMAYA_DESTDIR` | `/opt/glm-maya` |
| `--user NAME` | `GLMMAYA_USER` | `glmmaya` |
| `--quant Maya-XS\|Maya-S24\|Maya-S\|Maya-M\|Maya-L` | `GLMMAYA_QUANT` | `Maya-S` |
| `--gpu PCI` | `GLMMAYA_GPU` | chosen as described below (asked when two or more GPUs are usable) |
| `--ctx-size 262144\|524288\|786432\|1048576` | `GLMMAYA_CTX_SIZE` | `524288` |
| `--thinking none\|low\|high\|max` | `GLMMAYA_THINKING` | `max` |
| `--drafting skip\|measure\|on` | `GLMMAYA_DRAFTING` | `skip` |
| `--web-port PORT` | `GLMMAYA_WEB_PORT` | `48080` |
| `--interfaces all\|IF[,IF...]` | `GLMMAYA_INTERFACES` | `all` (asked when two or more interfaces have addresses) |
| `--web-api-key` / `--no-web-api-key` | `GLMMAYA_WEB_API_KEY` (`yes`/`no`) | `no` |
| `--agent-api-key` / `--no-agent-api-key` | `GLMMAYA_AGENT_API_KEY` (`yes`/`no`) | `no` |
| `--open-ports` / `--no-open-ports` | `GLMMAYA_OPEN_PORTS` (`yes`/`no`) | ask when ufw is active |

Never asked (option or environment variable only):

| Option | Environment variable | Default |
|---|---|---|
| `--parallel N` | `GLMMAYA_PARALLEL` | `1` (1 to 8) |
| `--vision` / `--no-vision` | `GLMMAYA_VISION` (`yes`/`no`) | `yes` |
| `--calibrate` / `--no-calibrate` | `GLMMAYA_CALIBRATE` (`yes`/`no`) | `no`; for this run only, not saved |
| `--maya-port PORT` | `GLMMAYA_MAYA_PORT` | `48081` |

Actions:

| Option | |
|---|---|
| `--yes` | answer yes to warnings, opening ufw ports and uninstalling |
| `--uninstall` | uninstall |
| `--help` | show the help |

GPU selection: the installer runs the model on one GPU. It lists the NVIDIA GPUs that answer to `nvidia-smi`, with their PCI addresses, total memory and memory in use, and asks which one to use when there are two or more. `--gpu` takes a PCI address as shown by `lspci -D` (e.g. `0000:03:00.0`). The default is the GPU with the largest memory, then the most free memory, then the lowest PCI address. So when another service (e.g. the llama-server of plamo-3-translate-installer-for-resolute) already uses one of two identical GPUs, the free one is the default. The PCI address is converted to the `nvidia-smi` number Maya takes at installation. Maya itself can split the model across several GPUs, but this installer does not offer that yet.

Context size: the maximum context length in tokens, one of four choices.

| `--ctx-size` | | RAM for the context, per conversation |
|---|---|---:|
| `262144` | 256K | about 1.6 GB |
| `524288` | 512K (default) | about 3.2 GB |
| `786432` | 768K. **Not mentioned anywhere by the Maya project.** | about 4.8 GB |
| `1048576` | 1M, the model's own maximum | about 6.4 GB |

Unlike the other engines of Maya, the GLM engine keeps a long context in RAM, not in GPU memory: each attention layer's cache lives in pinned RAM, and only a window of its 32768 most recently used positions is held on the GPU (Maya's "KV streaming", which its setup turns on in every configuration). The figures are estimates from Maya's own numbers (about 6 KB a token with the 8-bit cache that is Maya's default); the RAM is taken from what would otherwise hold experts. Maya's own setup offers 8K to 128K only (32K is its default), but passes any other number on unchecked, and its documentation reports 256K, 512K and 1M in use. Maya's smaller choices are not offered by this installer.

Thinking: the thinking level a request gets when it names none. Users can still choose another level in the web page or per request.

| `--thinking` | |
|---|---|
| `none` | no thinking (Off in the page). This is Maya's doing: the model itself always thinks, and Z.ai's own service does not let thinking be turned off. |
| `low` | Low |
| `high` | High |
| `max` | Max (default; the model's own default, and what Z.ai recommends) |

The levels are GLM's own (`Reasoning Effort: Low`, `High` or `Max` in its prompt). Maya's limit on the thinking in tokens (`thinking_budget`: 32768, or 8192 with `Maya-XS`) is left at Maya's default, so with `max` an answer can be preceded by a long wait. Maya also accepts `medium` (the same as `high`), `xhigh` and `auto` (both the same as `max`); they are not offered.

Whoever holds the API key can save a thinking level for all users in the settings of the web page. Maya keeps it beside its configuration (`maya-<name>.shared-settings.json`), and it then takes the place of `--thinking` for requests that name no level, also after a re-run of the installer, until it is cleared in the page. The installer warns at the end of an installation when it finds such a level that differs from `--thinking`, and also when it cannot read the saved settings (`GET /settings`).

Drafting: a drafter proposes several tokens ahead and the model checks them, so the answers stay the same and may come faster.

| `--drafting` | |
|---|---|
| `skip` | (default) Nothing is downloaded and nothing is measured. Maya is set to the model's own MTP block, which drafts only when the model is split over two or more GPUs; on the one GPU this installer uses, the model answers without drafting. |
| `measure` | Maya downloads the DFlash2 drafter (0.7 GB) and its speed calibration measures it during the installation (5 to 20 minutes, the model is loaded twice); the drafter is kept only if answers are more than 5% faster with it. |
| `on` | Maya downloads the DFlash2 drafter and uses it without measuring. |

- **The DFlash2 drafter ([Anbeeld/GLM-5.3-Flash-DFlash2-GGUF](https://huggingface.co/Anbeeld/GLM-5.3-Flash-DFlash2-GGUF)) is licensed under CC BY-NC-ND 4.0: non-commercial use only.** It is downloaded only with `measure` or `on`; the installer shows the license where it asks and in the summary.
- It needs a GPU with compute capability 8.0 or higher (RTX 30 series or newer); with `measure` or `on` on an older GPU the installer stops. Maya does not offer it on older GPUs, where it measured slower.
- It works for one request at a time: `measure` and `on` cannot be combined with `--parallel` above 1 (the installer stops).
- Whether it is faster depends on the machine. Where most of the model is read from RAM, checking the drafts can cost more than they save. A typical use is to install with `skip` first and to re-run with `--drafting measure` later.
- `measure` needs the selected GPU to itself: when more than 1 GiB of its memory is in use (a desktop session on that GPU is enough), Maya does not measure, leaves the drafter switched on and still ends without an error. The same happens when the measurement breaks off. The installer therefore looks at the GPU before Maya's setup (it warns and asks whether to continue), and after it at what Maya recorded: without a result it stops and asks for a re-run with `measure` when the GPU is free, with `on`, or with `skip`.
- `--drafting` is remembered like the other settings, so a later re-run without the option measures again after `measure`.

Parallel requests: `--parallel N` lets Maya answer up to N requests at once. Each conversation keeps a context of its own: the RAM in the table above times N, and for each extra conversation GPU memory for its window and its states, which is taken from the experts.

Pictures and video: GLM-5.3-Flash also reads pictures, video and files. With `--vision` (default), Maya compiles a second program, the image encoder (`maya-vision`; 10 to 20 minutes at the first installation), and downloads its files (1.14 GB), so that pictures can be attached in the chat and sent through the APIs. The encoder runs only while a request's pictures are read, in GPU memory the model lends it for that time. The installer also installs `ffmpeg` from apt, which Maya needs to read video (4 frames a second, up to one minute). `--no-vision` leaves all of it out: no image encoder, no download, no `ffmpeg`.

Tuning: with `--calibrate`, Maya's setup tunes the engine for the machine after the model is set up: it measures the real output speed with several splits of the work between the CPU and the GPU's PCIe link and with different numbers of CPU threads (10 to 15 minutes, most of it loading the model). It is off by default and is not remembered by the installer: run the installer once without it, check that the service works, and re-run it with `--calibrate` if wanted. Maya keeps the result (in the engine configuration and in `<destdir>/.config/project-maya/calibration.json`) and applies it again in later runs, but only for the same GPU, CPU, amount of RAM and quantization, the same `--vision` setting and the same use of the drafter (a result for another context size is taken when there is none for the selected one). After a change of one of these, tune again. Like `--drafting measure`, the tuning needs the selected GPU to itself (no more than 1 GiB of its memory in use): otherwise Maya only warns and tunes nothing. The installer checks the GPU before Maya's setup and warns after it when Maya did not write a result.

Network interfaces: when two or more network interfaces have global addresses (container/VM bridges such as `docker0`, `virbr0` and `lxdbr0` are ignored), the installer asks on which of them the web server accepts connections from other hosts (`all` or numbers). With selected interfaces, nginx listens on their current addresses plus `127.0.0.1` (and `::1`), and the ufw rules are limited to them (`ufw allow in on IF to any port PORT proto tcp`). The interface names are saved and the addresses are looked up at installation, so re-run the installer if an address changes. ufw rules added by an earlier run that are no longer wanted are removed.

API key: see [API key](#api-key).

### Files

```
<destdir>/                                  default /opt/glm-maya; home directory of the service user
  .glm-maya-installation                    marker checked by --uninstall
  .config/project-maya/calibration.json     result of --calibrate, kept by Maya
  project-maya/                             Maya's source tree (extracted release archive)
    .venv/                                  Maya's Python environment
    third_party/                            llama.cpp source at Maya's pinned commit
    build/maya                              the compiled GLM engine
    build-vision/bin/maya-vision            the compiled image encoder (with --vision)
    maya-<name>.json                        engine configuration written by Maya's setup, named after the quantization
    maya-<name>.shared-settings.json        settings saved in the web page for all users, kept by Maya (if any)
    maya-<name>.log                         engine log
    maya-setup.log                          output of the last run of Maya's setup (kept by the installer)
  models/
    <folder>/                               the model files of one quantization
      pack/                                 Maya's index of them; pack/slots holds kept conversations
      vision/                               files of the image encoder (with --vision)
    GLM-5.3-Flash-DFlash2/                  the DFlash2 drafter (with --drafting measure or on)
    refusal-directions/                     a small file Maya's setup downloads by itself (see Engine)
/etc/glm-maya/
  install.conf                              settings of the installation
  maya.env                                  API key (MAYA_API_KEY) and Maya's switches (root and the service user only)
  nginx-key.conf                            the same key for nginx (root only)
/etc/systemd/system/glm-maya.service        maya.sh --config .../maya-<name>.json (127.0.0.1:48081)
/etc/nginx/sites-available/glm-maya         (linked from sites-enabled)
/etc/logrotate.d/glm-maya                   rotation of the engine log
```

`<name>` and `<folder>` depend on the quantization; see the table under [Quantization](#quantization).

Maya's release archive (the archive of the tag v1.1.63) is downloaded from GitHub over HTTPS with `curl`; `git` is not needed. The installer does not verify the archive with a checksum. Everything else is downloaded and verified by Maya's setup: the llama.cpp source at a pinned commit, its Python packages from PyPI, and the model files, the image encoder's files and the drafter from Hugging Face, each checked against a SHA-256 checksum that is fixed in Maya's source. The one exception is the small "refusal direction" file (see [Engine](#engine)): Maya's setup fetches it again in every run from the `main` branch of Maya's model repository and checks only its format.

## Models

- GLM-5.3-Flash
  - https://huggingface.co/zai-org/GLM-5.3-Flash
  - https://docs.z.ai/guides/vlm/glm-5.3-flash
  - Quantized by Project Maya, with the files of the image encoder: https://huggingface.co/peasantsmith/GLM-5.3-Flash-Maya-GGUF
- DFlash2 drafter for GLM-5.3-Flash (optional, non-commercial)
  - https://huggingface.co/Anbeeld/GLM-5.3-Flash-DFlash2-GGUF

## License

### License of this repository

The files in this repository (the installer and the documentation) are distributed under the MIT License. See [LICENSE](LICENSE).

### License of GLM-5.3-Flash

The model files downloaded through the installer are not part of this repository. GLM-5.3-Flash is distributed by Z.ai under the MIT License, and so are the quantized files and the image encoder's files of Project Maya that the installer offers. The installer therefore does not ask for a license confirmation.

- **The DFlash2 drafter is distributed by Anbeeld under CC BY-NC-ND 4.0, for non-commercial use only.** It is downloaded only when `--drafting measure` or `--drafting on` is selected.
- Project Maya itself is distributed under the MIT License; it is built on ggml / llama.cpp (MIT License).
- The CUDA toolkit installed from the Ubuntu `multiverse` component is NVIDIA's proprietary software under NVIDIA's own license.
- `ffmpeg`, installed from the Ubuntu `universe` component with `--vision`, is distributed under its own licenses (LGPL / GPL).

## Engine

- Project Maya v1.1.63
  - https://github.com/mw00/project-maya/releases/tag/v1.1.63
- Maya publishes source only. The installer downloads the archive of the tag, and Maya's setup compiles the GLM engine (`build/maya`) on the machine with `cuda-toolkit-13` (CUDA 13.1) and the default `g++` (15.2) of Ubuntu 26.04. This takes 10 to 30 minutes at the first installation; the image encoder takes 10 to 20 minutes more.
- The version is pinned: Maya's update check is disabled (`MAYA_UPDATE_CHECK=0`), and the Update button of Maya's page cannot work without a git checkout. Updating Maya means updating this installer and re-running it.
- Maya's setup and `maya.sh` are always run as the service user, with destdir as its home directory.
- Maya's setup is run without starting the model (`--no-start`), so the model is loaded only once, by the systemd service. `--drafting measure` and `--calibrate` load it during the installation as well: these loads run inside the installer's session, not inside the systemd unit, so the installer lifts the limit on locked memory for Maya's setup itself (the unit has `LimitMEMLOCK=infinity`).
- Maya uses the sampling of the model's own configuration for requests that set none (temperature 1.0, top-p 0.95; with `Maya-XS` temperature 0.7, top-p 0.95, min-p 0.05).
- Conversations are kept: the GLM engine sets aside the conversations it is not working on (four of them by default, under the model folder's `pack/slots`, up to 16 GB, besides checkpoints in RAM), so that a web chat and a coding agent can take turns without the whole prompt being read again. The installer adds `MAYA_GLM_SLOT_KEEP=1`, with which they also survive a restart of the service; a conversation that is not used for seven days is removed.
- Maya's model management (downloading, deleting and switching models through the page or the Ollama-style `/api/*` paths) is turned off (`MAYA_MODEL_MANAGEMENT=0`). The model is selected by the installer only.
- Maya's setup also downloads a small file of its own, a "refusal direction" for GLM-5.3-Flash: one direction in the model's internal state (4096 numbers, a few KB) that goes with the model declining a request. The engine loads it switched off, and answers are then the same as without the file. A request can switch it on for itself (`"ablate": true`), and the web chat has a switch for it per chat: while such a request is answered, that direction is taken out of every layer's output, so the model also answers requests it would otherwise refuse. Other users' requests are not affected. The installer leaves this as Maya sets it up, off by default: a quantized model sometimes declines a harmless request by mistake, and this is the way around it.
- At start, the engine pins most of the free RAM (all but about 6 GB) and warms its caches; a start takes minutes.

## Quantization

Selected with `--quant`. All of them are Project Maya's own quantizations of Z.ai's FP8 release. The installer passes the setup id to Maya's setup (`--model <setup id>`).

| `--quant` | Maya's setup id | `<folder>` under `models/` | Engine configuration | Download | Memory for the whole model |
|---|---|---|---|---:|---:|
| `Maya-XS` | `glm-maya-xs` | `Maya-XS-IQ1_S` | `maya-maya-xs-iq1_s.json` | 73.4 GB | about 80 GB |
| `Maya-S24` | `glm-maya-s24` | `Maya-S24` | `maya-maya-s24.json` | 94.7 GB | about 102 GB |
| `Maya-S` (default) | `glm-maya-s` | `Maya-S-v2-IQ2_XXS` | `maya-maya-s-v2-iq2_xxs.json` | 96.5 GB | about 104 GB |
| `Maya-M` | `glm-maya-m` | `Maya-M` | `maya-maya-m.json` | 116.0 GB | about 124 GB |
| `Maya-L` | `glm-maya-l` | `Maya-L` | `maya-maya-l.json` | 156.3 GB | about 164 GB |

- The figures are from Maya v1.1.63 (`maya.py`, `docs/MODELS.md`, `docs/MEMORY.md`).
- Download: the model files. Maya also downloads, with `--vision`, the image encoder's files (1.14 GB) and, with `--drafting measure` or `on`, the drafter (0.7 GB), and builds its pack (about 1 GB) inside the model folder. Kept conversations take up to 16 GB more. The installer checks for the download size plus about 20 GB of free disk space.
- Memory for the whole model: GPU memory and RAM together that hold every expert, the context aside (see the table under [Options](#options)). With less, Maya keeps as many experts as fit and reads the rest from the SSD, which is much slower. The installer says so when the RAM and the memory of the selected GPU together are less than this figure plus the RAM for the context, and warns and asks whether to continue when the machine has less than 32 GB of RAM, the minimum Maya names.
- `Maya-S` keeps 97.9% of the zero-shot accuracy of the FP8 model and picks the same next token 83% of the time, as measured by the Maya project; `Maya-S24` 97.7% and 83%, `Maya-M` 97.9% and 86%, `Maya-L` 99.2% and 90%. Maya's documentation gives no figures for `Maya-XS`.
- `Maya-S24` is `Maya-S` with 4-bit attention, which leaves about 1.5 GB more of the GPU memory for experts. Maya's own setup recommends it instead of `Maya-S` when the GPU has 24 GB or less, where it answers about 14% faster; the installer says so where it asks.
- `Maya-XS` is made for machines with 64 GB of RAM and a 24 GB GPU. Maya gives it a smaller limit on the thinking (8192 tokens) and a sampling of its own.
- Not offered, although Maya's setup knows them: `Maya-M-Derisked` (`Maya-M` with a weight edit that reduces refusals; experimental) and turboderp's EXL3 quantizations.
- Unsloth's GGUF files of GLM-5.3-Flash are not offered: Maya's setup cannot download them. It only accepts such files when they are already on the disk, treats them as experimental and has no checksums for them.

## Architecture

```
web browser / coding agent
  → nginx (TCP 48080, on the selected network interfaces)
    → Maya server (127.0.0.1:48081; systemd unit glm-maya.service, service user)
      → Project Maya engine maya (child process of the server; GPU)
        → image encoder maya-vision (started by the server while pictures are read)
```

- Maya's server provides the web chat page with its monitor (`/`), the OpenAI-compatible API (`/v1/chat/completions`, `/v1/responses`, `/v1/models`) and the Anthropic-compatible API (`/v1/messages`) on one port. There is no `/v1/completions`, no `/v1/messages/count_tokens` and no embeddings endpoint.
- nginx (`nginx-full` from apt) is the only part reachable from other hosts. The site `glm-maya` does not use `default_server`, so it can live beside other sites (e.g. plamo-3-translate-installer-for-resolute on TCP 18080 and 28080, qwen-strata-installer-for-resolute on TCP 38080, deepseek-maya-installer-for-resolute on TCP 58080). Responses are not buffered (streaming), the timeouts are 3660 seconds and request bodies may be up to 256 MiB (pictures, video and files are sent inline).
- The service runs as the user given at installation (default `glmmaya`). If the user does not exist, it is created as a system user without login and with destdir as its home directory. An existing user is used only if its home directory is destdir.
- systemd unit: `Type=simple`, `maya.sh --config <destdir>/project-maya/maya-<name>.json --port 48081 --plain`, `EnvironmentFile=/etc/glm-maya/maya.env`, `LimitMEMLOCK=infinity` (the engine pins the experts and the context in RAM), `TimeoutStartSec=infinity`, `TimeoutStopSec=600` (the engine saves its conversations and frees the GPU), `KillMode=mixed`, `Restart=on-failure`, `RestartSec=30`, `After=plamo-3-translate-llama.service plamo-3-translate-uwsgi.service` and `Conflicts=deepseek-maya.service qwen-strata.service` (see [Coexistence with other services](#coexistence-with-other-services)). Sandboxing is light (`NoNewPrivileges`, `ProtectSystem=full`) until the service has been tested on real hardware.
- Logs: `journalctl -u glm-maya` (server) and `<destdir>/project-maya/maya-<name>.log` (engine; rotated weekly by logrotate with `copytruncate`).
- TLS is out of scope. The service is meant for an intranet, not for the internet.

### Coexistence with other services

- **[deepseek-maya-installer-for-resolute](https://github.com/astanabe/deepseek-maya-installer-for-resolute)** (`deepseek-maya.service`, TCP 58080 and 58081) and **[qwen-strata-installer-for-resolute](https://github.com/astanabe/qwen-strata-installer-for-resolute)** (`qwen-strata.service`, TCP 38080 and 38081): all three can be installed on one host, but only one of them runs at a time, because each needs a GPU and most of the RAM.
  - The unit declares `Conflicts=deepseek-maya.service qwen-strata.service` and the units of the other two installers name `glm-maya.service` in the same way, so starting one stops the one that is running.
  - If `deepseek-maya.service` or `qwen-strata.service` is running or enabled, the installer stops and disables it before Maya's setup (the summary shown before the installation says so). Maya's setup is not a unit start, so `Conflicts=` alone would leave the other service holding its GPU and RAM at that point. The installers of the other two do the same with `glm-maya.service`. The service installed or re-installed last is therefore the one that runs and that starts at boot.
  - Switch by hand with `sudo systemctl disable --now deepseek-maya qwen-strata && sudo systemctl enable --now glm-maya`, or likewise for one of the others. Keep only one of the three enabled: with more than one enabled, systemd starts only one of them at boot, and which one is not defined.
  - `--uninstall` does not enable `deepseek-maya.service` or `qwen-strata.service` again; it prints the commands to do so.
  - While `deepseek-maya` or `qwen-strata` is running, its GPU counts as in use for the default GPU selection, so on a first installation give `--gpu` (or answer the question) if they are meant to use the same GPU.
  - The installers of the other two know `glm-maya.service` since 2026-11-17 (qwen-strata: commit `b347c2b`; deepseek-maya: commit `9dd4b3a`). An older copy of one of them leaves `glm-maya` running and enabled when it installs or re-installs its service: use a current copy, or stop `glm-maya` first with `sudo systemctl disable --now glm-maya`, otherwise their setup finds the GPU and the RAM taken, and two services stay enabled. An installation that was made with an older copy need not be repeated for this: `Conflicts=` works in both directions, also when only one of the two units declares it.
- **[plamo-3-translate-installer-for-resolute](https://github.com/astanabe/plamo-3-translate-installer-for-resolute)** (`plamo-3-translate-llama.service`, `plamo-3-translate-uwsgi.service`, TCP 18080 and 28080): can run at the same time, on another GPU. Because Maya pins most of the RAM that is free when it starts, the unit is ordered after the two plamo services.
  - `plamo-3-translate-llama.service` counts as started only when its model is loaded (it waits for the `/health` of its llama-server), so at boot Maya starts after llama-server has taken its memory. This needs a plamo-3-translate installation made with its installer of 2026-11-15 or later (commit `0d8bc4e`); with an older one, re-run that installer, otherwise the order only says that llama-server has been started.
  - The same wait applies to `systemctl start glm-maya` or `restart`, and to the start at the end of this installer, while `plamo-3-translate-llama.service` is still loading its model: the command returns when Maya has been started after that. There is no time limit on the plamo side.
  - If llama-server exits while it loads its model, `glm-maya` is started when that first attempt has failed; it does not wait for the retries.
  - Restarting the plamo services while Maya runs leaves them only the few GB Maya left free; restart `glm-maya` afterwards in that case.

### API key

Maya has a single API key that is either required for everything except the web page itself and `/health`, or not set at all. Without a key, Maya trusts requests from `127.0.0.1` for its management functions, and behind nginx every request comes from `127.0.0.1`. The installer therefore always sets a key in Maya (generated at the first installation, kept afterwards) and lets nginx add it to the requests that are meant to work without one. The key is never written into the nginx site file; nginx reads it from `/etc/glm-maya/nginx-key.conf`.

| Path | Default | Key required with |
|---|---|---|
| `/`, `/web/`, `/fonts/`, `/health` | passed on as is (Maya needs no key for them) | — |
| what the web page needs for chatting: `GET /metrics`, `POST /attach`, `POST /pdf`, `POST /api/tokens`, `GET /v1/strata/stream`, `POST /v1/strata/cancel`, and `GET` of `/settings`, `/mcp`, `/api/context`, `/api/thinking-budget`, `/api/turbo`, `/api/savings` and `/api/update` (read-only; the page asks `/api/update` when it is loaded) | nginx adds the key | `--web-api-key` |
| `/v1/chat/completions` (used by the web page and by agents) | nginx adds the key | `--web-api-key` for the web page, `--agent-api-key` for other clients |
| `/v1/messages`, `/v1/responses` and `/v1/responses/...`, `/v1/models`, `/models`, `/props`, `/tokenize`, `/detokenize` | nginx adds the key | `--agent-api-key` |
| everything else: management (`POST` of `/settings`, `/api/context`, `/api/port`, `/api/thinking-budget`, `/api/turbo`, `/api/update`, `/api/models/...`, `/api/savings/...`; `/status`, `/v1/status`, `/slots`, `/metrics/prometheus`, `/api/report`, ...) | passed on as is: **the key is always required** | — |

- Maya's server is the same program for all its models, so the paths are those of deepseek-maya-installer-for-resolute.
- nginx decides by the normalized path, and where it adds the key Maya is sent exactly that path, so `..` or doubled slashes cannot borrow the key for another path.
- Where nginx adds the key, it replaces the client's `Authorization` header and removes `x-api-key`, so that the placeholder key that SDKs and agents insist on sending does not cause a 401. With the defaults, coding agents can be configured with any non-empty string as the API key.
- With `--web-api-key`, enter the key in the settings of the web page. The same is needed to use the management functions of the page (context size, port, thinking budget, Turbo); without the key they fail, while chatting works.
- `/v1/chat/completions` is shared by the web page and the agents. When `--web-api-key` and `--agent-api-key` differ, nginx decides whether a request comes from the web page by the headers browsers add: `Sec-Fetch-Site: same-origin`, or, where the browser does not send `Sec-Fetch-Site` (browsers send it only to HTTPS and localhost origins, and this site is plain HTTP), an `Origin` header that equals the `Host` header. **Other clients can forge these headers**, so requiring the key on one side only guards against mistakes, not against users who want to get around it. Require it on both sides when that matters.
- Anyone who holds the key can change Maya's settings for all users, including the context size and the port (changing the port through the page breaks the service until the installer is re-run).
- Show the key: `sudo sed -n 's/^MAYA_API_KEY=//p' /etc/glm-maya/maya.env`

## Client

- Web browser (PC and smartphone): `http://<server>:48080/`
- Coding agent, OpenAI-compatible: base URL `http://<server>:48080/v1`
- Coding agent, Anthropic-compatible: base URL `http://<server>:48080` (e.g. Claude Code: `ANTHROPIC_BASE_URL=http://<server>:48080`)

The model name (`glm-5.3-flash`) is reported by `/v1/models`, together with the context size (`context_length`). Thinking can be set to Off, Low, High or Max, in the page or per request; without that, the level given with `--thinking` applies. Files (PDF, office documents, text) can be attached in the page or sent inline through either API, and with `--vision` pictures and video as well.

The reasoning is returned as `reasoning_content` (Chat Completions), as reasoning items (Responses) and as thinking blocks (Messages). When a client sends it back with the conversation, the model reads it again in the next turn; `"chat_template_kwargs": {"clear_thinking": true}` leaves the reasoning of past turns out, which is what Z.ai recommends for chat.

When the model declines a request it should not have declined, the request can be sent again with `"ablate": true` (both APIs), or with the Refusal ablation switch of the chat's settings in the web page; see [Engine](#engine).

## Procedure

1. Ask the user for destdir (default `/opt/glm-maya`), user name (default `glmmaya`), quantization (default `Maya-S`), GPU (only if two or more are usable), context size (default 524288), thinking level (default `max`), drafting (default `skip`), web server port (default 48080), network interfaces to listen on (only if two or more have addresses), whether the web page and the agents need the API key (default no for both), and whether to open the port in ufw (only if ufw is active and the port is not allowed yet); show a summary
2. Check prerequisites: Ubuntu 26.04 on x86_64 and not WSL, AVX2, the NVIDIA driver (580 or later) and the selected GPU (compute capability 7.5 or higher; 8.0 or higher with `--drafting measure` or `on`), the ports are not in use, destdir is empty or a previous installation, the service user's home directory, free disk space and memory (warn and ask to continue if insufficient)
3. Install missing dependencies via apt: `cuda-toolkit-13 build-essential python3 python3-venv nginx-full curl ca-certificates tar pciutils`, and `ffmpeg` with `--vision`
4. Create the service user if needed and prepare destdir
5. Stop the existing `glm-maya` service; stop and disable `deepseek-maya.service` and `qwen-strata.service`, each if it is running or enabled (Maya's setup and the engine need the GPU and the RAM). With `--drafting measure` or `--calibrate`, warn and ask whether to continue if more than 1 GiB of the selected GPU's memory is still in use
6. Download Maya's release archive and extract it into `<destdir>/project-maya` (skipped when the pinned version is already there)
7. Generate the API key, or reuse the existing one, and write `maya.env` and `nginx-key.conf`
8. Run Maya's setup once as the service user, without questions and without starting the model (`maya.sh --setup --yes --plain --no-start --download-model --model <setup id> --gpu N --context N --port N --parallel N --models-dir <destdir>/models --env MAYA_GLM_SLOT_KEEP=1`, with `--draft mtp`, or `--draft dflash2 --drafting measure` or `on`, with `--no-vision` when pictures are not wanted, and with `--calibrate` when asked for): it creates `.venv`, fetches the llama.cpp source, compiles the engine, downloads and checks the model, builds the pack, compiles the image encoder and downloads its files, writes `maya-<name>.json`, and measures and tunes when asked. Maya's setup also ends without an error when it has done nothing, only warns when the image encoder could not be built, and skips its measurements when the GPU is in use, so the installer checks afterwards that the configuration was written in this run and is for the selected quantization, that the engine and the pack named in the configuration exist, with `--vision` that the configuration names the image encoder and that it exists, and with `--drafting measure` that Maya recorded a result (otherwise it stops); with `--calibrate` it warns when Maya wrote no result. Then set the thinking level in `maya-<name>.json` (`reasoning_effort`), because Maya's setup has no option for it and writes `max` on every run, and remove the configurations and start scripts of other quantizations
9. Write the systemd unit, the nginx site and the logrotate configuration, test the nginx configuration (on failure the site is disabled again so that other sites are not affected), enable and start the service
10. Configure ufw as answered in step 1 (if ufw became active after step 1, ask here) and save `install.conf`
11. Test: wait until `/health` of Maya answers 200 with the model loaded, then check through nginx that `/health` works, that a management request is refused without the key and accepted with it, that the key requirement of `/metrics` and `/v1/models` matches the settings, that `/v1/models` reports the selected context size, and that a short chat completion is answered; the thinking level `/health` reports is shown, with a warning when it is not the selected one or when another level was saved in the settings of the web page. If the quantization changed, offer to delete the model files of the other quantizations

## Known limitations

- Nothing has been run on real hardware (see below).
- NVIDIA GPUs of the RTX 20 series or newer only. AMD GPUs, Intel Arc, older NVIDIA GPUs (V100, GTX 10) and WSL are not supported.
- One GPU only; Maya's multi-GPU operation is not offered. On one GPU the model's own MTP block does not draft; the only drafter is DFlash2, which is licensed for non-commercial use only.
- `--drafting measure` and `--calibrate` need the selected GPU free (no more than 1 GiB of its memory in use). On a Desktop whose display runs on that GPU this may not be possible without stopping the desktop session.
- Project Maya's own quantizations only; Unsloth's GGUF files, EXL3 quantizations and `Maya-M-Derisked` are not offered.
- None of the four context sizes is among the choices of Maya's own setup; 768K is not mentioned by the Maya project at all.
- Does not run at the same time as the services of deepseek-maya-installer-for-resolute and qwen-strata-installer-for-resolute; installing one of the three stops and disables the other two.
- While Maya runs, other programs get little RAM.
- Requiring the API key for only one of the web page and the agents depends on request headers and can be circumvented on purpose.
- With the default settings anyone on the networks the web server listens on can use the model without a key; only the management functions are protected. This includes switching on Maya's refusal ablation for one's own requests.
- Maya's model management and its Ollama-style API are turned off, and Maya cannot update itself.
- Kept conversations use up to 16 GB under `models/` in addition to the figures in the table.
- Claude Code and other Anthropic-compatible clients that call `/v1/messages/count_tokens` get a 404 for that call.
- TLS is out of scope.

## Verification

The installer has not been run on real hardware. The development machine has no supported GPU: what is written here about Maya comes from reading the documentation and the source of Maya v1.1.63 (2026-11-17), what is written about the model from Z.ai's documentation and model card, and what is written about the apt packages from the package index and the package contents of Ubuntu 26.04.1 (`cuda-toolkit-13` 13.1.1 in `multiverse`; its headers accept GCC up to 15; `nvcc` is installed as `/usr/local/cuda-13.1/bin/nvcc`, where Maya looks for it).

Checked on the development machine (2026-11-17), without root and without a GPU, by sourcing the installer into test scripts (as for deepseek-maya-installer-for-resolute):

- `bash -n` and `shellcheck` 0.11 (no findings)
- Settings: the order option, environment variable, `install.conf`, default; every invalid value stops the installer (among them `Maya-M-Derisked`, a context size outside the four choices, `--thinking medium`, `xhigh`, `auto` and a number, `--drafting off`, `--drafting on` and `measure` with `--parallel` above 1); `--calibrate` is neither saved nor read from `install.conf`
- The questions on a pseudo-terminal, and the note about `Maya-S24` (shown when no usable GPU, or the one named with `--gpu`, has more than 24.5 GB)
- GPU selection with a stand-in for `nvidia-smi` (the default, the conversion of the PCI address to Maya's number, a saved GPU that is gone), the driver floor, the compute capability (7.5, and 8.0 for the drafter), the memory check (the whole model plus the RAM for the context times `--parallel`), the disk space check, and the warning about a GPU in use with `--drafting measure` or `--calibrate`
- Generated files: the systemd unit for each quantization (`systemd-analyze verify` reports nothing), the logrotate file (`logrotate -d` with a user that exists), `install.conf`, `maya.env` and `nginx-key.conf` (the key kept on a re-run), the removal of the site link when `nginx -t` fails
- `deepseek-maya.service` and `qwen-strata.service` with a stand-in for `systemctl`: each and both, enabled or running, are announced in the summary and stopped and disabled; installed but idle, or not installed, nothing is done; the hints after `--uninstall`
- Maya's setup with a stand-in for `maya.sh` and for the release archive: the arguments for every combination of the five quantizations, the three `--drafting` settings, `--vision` and `--calibrate`; its environment; the checks afterwards (a setup that fails, that does nothing, that writes the configuration of another quantization, without the engine, without the pack, without the image encoder, with a measurement that did not run or broke off, without a tuning result); `reasoning_effort` for each level with the rest of the configuration (among it the refusal ablation) left as it was; the removal of an API key from the configuration; the removal of the configurations of other quantizations, each by its name; a tree of another version replaced with the configuration carried over
- The nginx site in a private nginx in front of a small server that enforces the key as Maya does: the four combinations of `--web-api-key` and `--agent-api-key`, for every path of the table under [API key](#api-key), without a key, with a placeholder key and with the real one, as a page and as another client, `GET` against other methods, and paths with `..`, encoded dots and slashes, doubled slashes and trailing slashes
- The installer's own tests at the end against that server, including the warnings about the thinking level (another level reported by `/health`, another level saved in the page, `GET /settings` not readable), and the whole installation from the summary to the final message with stand-ins for apt, `useradd`, `systemctl` and Maya (first installation, a re-run with another quantization, a re-run from `install.conf`, a failed measurement, `--uninstall`)
- The offer to delete other quantizations: only their own folders, never `GLM-5.3-Flash-DFlash2/`, `refusal-directions/` or a folder the installer does not offer (`Maya-M-Derisked`); not with `--yes`

The stand-ins behave as the source of Maya v1.1.63 was read; they prove nothing about Maya itself.

To be done on real hardware (planned machine: Ryzen Threadripper PRO 3995WX, 512 GB DDR4-3200, GeForce RTX 5080 Ti 12 GB):

- `apt-get install --no-install-recommends cuda-toolkit-13` provides `nvcc` (the installer stops after apt if it finds none)
- The GPU selected by PCI address is the one Maya loads (compare the memory in use per GPU in `nvidia-smi`)
- The engine and the image encoder build with `cuda-toolkit-13`, `g++` 15.2 and Python 3.14 (Maya's Python packages install into `.venv`); if the build refuses the compiler, `g++-14` with Maya's `--host-compiler g++-14` is the fallback
- Maya's setup runs to the end without a terminal and without questions with `--yes --plain --no-start --download-model`, accepts `--model glm-maya-s` and the other setup ids, and names the folder, the pack and the configuration as in the table under [Quantization](#quantization)
- The service starts with each context size on the 12 GB GPU (Maya's setup never offers them itself), `/v1/models` reports it, and the RAM a context takes is about what the table says
- `MAYA_API_KEY`, `MAYA_MODEL_MANAGEMENT=0` and `MAYA_UPDATE_CHECK=0` from the unit's `EnvironmentFile` are what the server enforces
- Each `--thinking` value is accepted at start, and `none` gives an answer without thinking
- `--drafting measure` and `on` (the download, the measurement, what the configuration keeps: `installer.speed_calibration` with `kept`, as the installer reads it), a measurement while the GPU is in use (the installer stops), and a re-run with `skip` afterwards
- Pictures, a PDF and a short video in the web chat and through the APIs
- `--calibrate`: the time it takes, what it writes (`calibration.json` in `<destdir>/.config/project-maya/`), and that a later run without it keeps the result
- The engine loads of `--drafting measure` and `--calibrate` during Maya's setup: whether the lifted limit on locked memory reaches the engine through `runuser` (`ulimit -l` of the engine process), and whether `systemd-oomd` or the memory limits of the session the installer runs in (it is not the unit's cgroup) get in the way
- A complete installation, a re-run, a re-run with another quantization (the old configuration removed, the service started with the new one), and `--uninstall`
- The body of `/health` (`"status": "ok"`, `"unloaded": false`, `max_context`, `model`, `defaults.reasoning_effort`), of `/v1/models` (`context_length`) and of `GET /settings` (`defaults.reasoning_effort` after a level was saved in the page) as the installer reads them, and `GET /status` as the management request of the final test
- `logrotate -d /etc/logrotate.d/glm-maya`
- Through nginx: a reply in the web chat (PC and smartphone) without an "API key needed" message when `--web-api-key` is off, replies from `/v1/chat/completions` and `/v1/messages`, 401 for a management request without the key and 200 with it; the list of paths the web page needs (see [API key](#api-key)) is complete
- A web chat and a coding agent taking turns reuse their kept conversations, also after a restart of the service
- `systemctl stop` and `restart` timings
- Whether `systemd-oomd` leaves the service alone while it loads (Maya's setup warns about it on machines with 128 GB of RAM or more)
- With deepseek-maya-installer-for-resolute and qwen-strata-installer-for-resolute installed: installing any one of the three stops and disables the other two, `systemctl start` of one stops the one that is running, and only the enabled one starts at boot
- Side by side with plamo-3-translate-installer-for-resolute, each on its own GPU, and after a reboot Maya started only when the llama-server of plamo-3-translate has loaded its model (`systemd-analyze critical-chain glm-maya.service`, journal timestamps)
- Speed (reading a prompt and writing an answer) with `Maya-S`, `Maya-S24` and `Maya-L` at 256K, 512K, 768K and 1M, with each thinking level, and whether `--drafting measure` keeps the drafter
