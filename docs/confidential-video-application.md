# Confidential Video Generation — Application Requirements (separate software repo)

Scope: everything that runs inside the TEEs, plus the operator client. Infrastructure is owned by
the infrastructure repo — see `confidential-video-generation-infrastructure-plan.md` (§4 interface
contract). Decisions, assumptions and open questions: `confidential-video-generation-decisions.md`.

## 1. Threat model and roles
- Google must not read prompts, storyboards, CPU/GPU memory, intermediate state, keys or outputs.
- **All inference runs inside the GPU TEE** (director LLM, video models, any audio model, future
  critic/image models). No cloud AI APIs, no inference on the operator laptop.
- **Operator laptop role:** orchestration, management, authorisation (attestation checks, key
  release, unseal) and decrypting the final video only.
- No Google-managed key may protect plaintext. Root unseal secret originates off-GCP and is
  supplied per keystore boot. Initial secret store: Dashlane (read via Dashlane CLI, never the
  clipboard); YubiKey is a later upgrade. Client secret source must be pluggable.
- Do not use Google Cloud Attestation or Confidential Space tooling in the trust path; verify
  evidence directly (Intel DCAP / go-tdx-guest, AMD SEV-SNP verification, NVIDIA verifier) or via
  Intel Trust Authority.

## 2. Pipeline overview (own director pipeline)

```
Operator prompt (+ options: target length, model preference, audio on/off)
 → Director (LLM, in TEE): outline, character/style bible, shot list (JSON schema)
 → Shot scheduler: groups shots by selected video model, minimises model swaps
 → Shot generation (video model, in TEE): per-shot T2V/I2V, conditioned on bible text and,
   for continuous shots, previous shot's last frame
 → [optional] Audio post-processing (in TEE) if the selected video model has no native audio
 → Editor (ffmpeg, in TEE): stitch, transitions, audio crossfades/levelling
 → Sanitise (§8) → encrypt → `outputs` bucket
```

- Target length: 2–5 minutes initially; 10 minutes as a stretch goal.
- Shots are typically 5–10 s; a 5-minute video is ~30–60 shots.
- Orchestration in plain, auditable code (Python inside the TEE); no third-party agent framework
  required for phase 1.

## 3. Model registry (multi-model, selectable per job/shot)
- The workload image contains an **approved model catalogue**: for each model a manifest with
  model ID, weight files and SHA-256 hashes, pipeline adapter, capabilities (native audio, max
  resolution, max duration, T2V/I2V, multi-shot), VRAM profile, licence obligations.
- Jobs select a model per job (default) or per shot (override). The director may only choose from
  the catalogue.
- Only one large model is resident on the GPU at a time; the scheduler sequences phases and
  batches shots per model. Weights not in use may be held in host RAM (234 GB) to speed swaps.
- Adding a model = new manifest + adapter in a new image build → new measurements pinned by the
  client and KBS. Weights are uploaded to the `model-weights` bucket.
- Common adapter interface: `generate(shot, conditioning) -> clip (+ optional audio)`.

### 3.1 Catalogue roadmap

| Model | Role | Status |
|---|---|---|
| LTX-2.5 (FP8/distilled) | Video + native audio; multi-shot; extend | **Phase 1 default** |
| Qwen3-family instruct LLM (Apache 2.0, ~14–32B, FP8) | Director | **Phase 1** (exact model per §4) |
| Wan 2.2 T2V/I2V-A14B | Video (no audio) | **Long-term goal**; add once pipeline is stable |
| Video-to-audio model (e.g. MMAudio) | Audio for silent models | Added with Wan; licence check (non-commercial acceptable) |
| Kandinsky 6.0 Pro | Video + audio, MIT | Optional candidate |

### 3.2 Licence obligations
- **LTX-2.x Community License:** non-commercial use permitted; must not remove, disable or
  circumvent model-applied watermarking, provenance, latent-disclosure or safety features
  (§6, Attachment A item 19); Attachment A and the AUP apply (no non-consensual impersonation;
  label as machine-generated if placed in any public context). No phone-home enabled; TEE runs
  offline.
- Every catalogue entry records its licence and obligations; sanitisation respects them (§8).

## 4. Director
- Runs in the GPU TEE on the shared H100, before shot generation (GPU freed after planning).
- Model: latest Apache 2.0 Qwen3-family instruct model that fits the planning budget (target
  ~14–32B in FP8, ≤ ~35 GB VRAM). Final choice by benchmark (planning quality vs load time).
- Serving: vLLM (offline mode) or Transformers, with schema-constrained JSON output.
- Output: storyboard JSON (scenes, shots, durations, camera, characters/style bible references,
  continuity flags, transitions, audio cues, model per shot).
- Storyboard is internal to the TEE; the operator sees only the final video (optional review
  gate: see decisions Q3).
- Prompt extenders of individual video models are disabled; the director is the only prompt
  writer.

## 5. Audio
- Native audio from the video model is preferred (LTX-2.5).
- Audio is optional per job; silent output is acceptable when video quality is better.
- Any post-processing audio generation runs in the same TEE under the same rules (offline,
  catalogue-approved, hashed weights, sanitised output).

## 6. Images and artefacts (built with Packer/mkosi, published to the infra project)
- **Workload image (TDX):** Ubuntu with TDX guest support, NVIDIA driver with confidential-computing
  support (open kernel modules), CUDA 12.x, PyTorch, FlashAttention, Diffusers, torchao, vLLM,
  ffmpeg, model adapters, catalogue manifests, Trustee attestation-agent, in-VM agent. No SSH, no
  Google guest agent, no Ops Agent. dm-verity root. Pinned keystore identity.
- **Keystore image (SEV-SNP):** Trustee KBS + attestation service + RVPS, unlock service, admin
  tooling. Same hardening.
- **Model weights:** downloaded with `hf` CLI in CI, uploaded to `model-weights` (FP8/BF16 only).
  Loaded at boot or on first use and verified against catalogue hashes.
- Dependencies locked with hashes; SBOM (syft), Trivy scan; CI publishes expected measurements
  (MRTD/RTMRs, SNP launch measurement, GPU RIMs) for the client and KBS to pin.
- Firmware measurement checked with gce-tcb-verifier. CI keeps current + previous image only.

## 7. Keystore (Trustee KBS, GCP-hosted)
- **Unlock:** KBS state on a LUKS volume (Trustee local filesystem storage). An unlock service in
  the keystore TEE presents its SEV-SNP report over RA-TLS; the client verifies it and sends the
  unseal secret. Secrets exist only in keystore TEE memory.
- **Self-identity:** keystore TLS key generated inside the TEE; GPU VM trusts it via attestation
  or pinned identity.
- **Workload attestation:** KBS verifies TDX quote and NVIDIA H100 evidence against reference
  values and a release policy (confirm Trustee NVIDIA verifier maturity; fallback custom check).
- **Key release:** encrypted to the TEE-generated ephemeral key bound in the evidence.
- **Collateral:** Intel PCS and NVIDIA RIM/OCSP via the keystore-only egress path; provide the
  endpoint list to the infra repo; optional cache with refresh before expiry (~30 days).
- **Admin:** admin key off-GCP; signed policy/reference-value updates. Restart requires re-unlock.

## 8. Session and job flow
1. Client starts the keystore VM, attests it, sends the unseal secret.
2. Client scales the GPU MIG to 1.
3. GPU VM boot: attestation-agent → KBS; scratch key released; LUKS scratch unlocked; GPU set to
   CC ready state.
4. Client attests the GPU VM over RA-TLS (IAP TCP forwarding), sends per-job keys and jobs
   (prompt, target length, model preference, audio flag). Operator need only be present to start;
   jobs then run unattended.
5. Director → scheduler → shot generation → (audio) → editor → sanitise → encrypt → upload.
6. **Checkpointing:** each completed shot is encrypted with the job key and written to
   `outputs/<random-job-prefix>/parts/` so a preempted job (Spot/flex-start end) can resume;
   parts are deleted after the final upload.
7. Client downloads the final ciphertext, decrypts, runs the sanitisation check; scales MIG to 0
   and stops the keystore; per-job keys retained or destroyed.

## 9. Runtime confidentiality controls (in-VM)
- Scratch only in tmpfs or LUKS2 volume keyed by the keystore.
- Swap off, core dumps off, no `nvidia-bug-report`, no hibernation.
- Offline/telemetry flags: `HF_HUB_OFFLINE=1`, `HF_HUB_DISABLE_TELEMETRY=1`, `DO_NOT_TRACK=1`,
  vLLM usage stats disabled (`VLLM_NO_USAGE_STATS=1`), no wandb or similar.
- Logs: status codes only; no prompts, storyboards, filenames or frame data. No writes to
  metadata/guest attributes.
- GPU VM network: Cloud Storage and keystore only (enforced by infra firewall).
- ComfyUI must not be used inside the TEE.

## 10. Output sanitisation
AI-generated / model identification is permitted. Any data identifying the user, host, project,
job, time or infrastructure must be removed.

- **Model-licence carve-out:** disclosure/watermark/provenance features applied by a model
  (e.g. LTX-2.x) must be preserved. If such a feature carries identifying data, raise it as a
  conflict before release; do not strip it.
- **S1** Any label may state AI-generated / model name only; no identifying payload.
- **S2** Strip container metadata (other than model-applied disclosures): `-map_metadata -1
  -map_chapters -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact`; no
  `udta`/`meta`/`uuid`/XMP/C2PA boxes carrying identifying data.
- **S3** Remove encoder fingerprints: x264 `-bsf:v filter_units=remove_types=6`; x265
  `-x265-params info=0`.
- **S4** No identifying filenames or timestamps; random object names; no custom GCS object
  metadata; content type `application/octet-stream`.
- **S5** Automated verification (ffprobe + MP4 box scan) in the VM before encryption; job fails on
  violation. Client repeats after decryption and normalises file timestamps.
- **S6** S2–S5 apply to every intermediate and final artefact; only encrypted parts and the
  sanitised final leave the TEE.
- **S7** Optional client-side AI label (C2PA or visible) with neutral, non-identifying signer.
- Accepted risk: model style artefacts may reveal the generator; permitted.

## 11. Client tool (operator laptop, Go)
- Start/stop keystore, scale GPU MIG (resize/resize request), IAP TCP tunnels.
- Verify SEV-SNP, TDX and NVIDIA evidence against pinned measurements.
- Unseal keystore from Dashlane CLI; generate and send per-job keys.
- Submit jobs (prompt, length, model preference, audio flag); show progress status codes only.
- Download/decrypt final outputs, run S5 check, optional S7 label.
- No local inference.

## 12. Acceptance / benchmarks (phase 1)
- Director: storyboard quality and load time for 2–3 Qwen3-family sizes on one confidential H100.
- LTX-2.5: time and quality per 720p shot with audio; multi-shot vs per-shot continuity.
- Model swap cost (director → LTX) and host-RAM caching benefit.
- End-to-end: 2-minute and 5-minute videos; resume after forced preemption.
- Session overhead: boot, attestation, key release, weights load and hash check.
- Verify S3 encoder settings keep acceptable quality; inspect outputs for model-applied disclosures.
- Negative tests: wrong workload measurement, missing GPU evidence, or locked keystore must block
  key release.

## 13. Long-term feature pipeline (learned from ViMax; not in early phases)
ViMax (HKUDS, MIT) is a design reference; its cloud providers must not be used. Candidate
features, each to be implemented with in-TEE models only:
- Character/style reference images per character (local image model, e.g. Qwen-Image) for
  cross-shot consistency.
- Critic/QA agent (local vision-language model) scoring shots and triggering regeneration.
- Camera-continuity and first-frame planning across scenes.
- Script2Video (operator-supplied screenplay) and Novel2Video (long-form adaptation).
- Cameo from operator-supplied reference photo (consent rules apply).
- Interactive agent loop / storyboard revision (subject to the laptop-role constraint).
- Parallel shot generation (requires multi-GPU confidential capacity; not available today).
- Separate music bed and dialogue/TTS models for richer audio.
- Wan 2.2 (and future open Wan releases) added to the catalogue.
